-- ~/.hammerspoon/modules/clamshell_guard.lua
-- Clamshell & Bag Overheating Safeguard
-- Silently monitors for closed-lid "in a bag" conditions on battery power.
-- 1. If an active audio/mic recording or media stream is keeping the Mac awake when
--    the lid shuts, immediately dispatches a private silent alert to Matt's iPhone via iMessage.
-- 2. If the Mac is unattended in a closed bag (no remote interaction) and sustains high CPU
--    (>20%) for 3+ minutes, forces system sleep as a circuit breaker to protect the battery and SoC.

local M = {
  id = "clamshell_guard",
  name = "Clamshell & Bag Safeguard"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local HERMES_BIN = "/Users/matt/.local/bin/hermes"
local lastAlertTime = 0
local ALERT_COOLDOWN_SECONDS = 10 * 60 -- 10 minutes debounce
local highCpuCount = 0
local HIGH_CPU_THRESHOLD_PERCENT = 20.0
local HIGH_CPU_CONSECUTIVE_LIMIT = 3 -- 3 checks * 60s = ~3 minutes

-- Check if Mac is in a closed-lid, standalone bag scenario on battery
local function isBagScenario()
  local onBattery = hs.battery.powerSource() == "Battery"
  if not onBattery then return false end

  local screens = hs.screen.allScreens()
  -- If more than 1 screen, user has an external monitor attached (desktop clamshell)
  if #screens > 1 then return false end
  -- If exactly 1 screen is active, the built-in laptop screen is open
  if #screens == 1 then return false end

  -- Closed lid on battery with no external display leaves 0 active screens
  return #screens == 0
end

-- Asynchronously dispatch an iMessage via the Hermes Photon gateway
local function sendIMessageAlert(messageText)
  if not hs.fs.attributes(HERMES_BIN) then
    print("⚠️ [clamshell_guard] Hermes CLI binary not found at: " .. HERMES_BIN)
    return
  end

  hs.task.new(HERMES_BIN, function(exitCode, stdOut, stdErr)
    if exitCode == 0 then
      print("✓ [clamshell_guard] iMessage alert delivered to iPhone")
    else
      print("⚠️ [clamshell_guard] Failed to send iMessage alert: " .. tostring(stdErr or stdOut))
    end
  end, { "send", "--to", "photon", messageText }):start()
end

-- Inspect whether coreaudiod or Chrome is asserting sleep prevention
local function getActiveRecordingDetails()
  local assertions = hs.execute("pmset -g assertions") or ""
  local hasAudioIn = assertions:match("audio%-in") ~= nil
  local hasPlayingAudio = assertions:match("Playing audio") ~= nil
  local hasVideoLock = assertions:match("Video Wake Lock") ~= nil

  if not (hasAudioIn or hasPlayingAudio or hasVideoLock) then
    return nil
  end

  -- Attempt to get relevant Chrome tab name if Chrome is running
  local chromeScript = [[
tell application "System Events"
    if exists (processes where name is "Google Chrome") then
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    set ttl to title of t
                    if u contains "genio.co" or ttl contains "Recording" or ttl contains "Notes" then
                        return ttl
                    end if
                end repeat
            end repeat
            try
                return title of active tab of front window
            on error
                return ""
            end try
        end tell
    else
        return ""
    end if
end tell
]]
  local ok, tabTitle = hs.osascript.applescript(chromeScript)
  local detail = ""
  if ok and tabTitle and tabTitle ~= "" then
    detail = " Chrome Tab: \"" .. tabTitle .. "\""
  elseif hasAudioIn then
    detail = " Microphone / Audio Input active"
  else
    detail = " Media playback / Wake lock active"
  end

  return detail
end

-- Immediate check triggered when the screen sleeps / lid closes
local function checkImmediateLidClose()
  if not isBagScenario() then return end

  local recordingDetail = getActiveRecordingDetails()
  if recordingDetail then
    local now = os.time()
    if now - lastAlertTime >= ALERT_COOLDOWN_SECONDS then
      lastAlertTime = now
      local alertMsg = "⚠️ Mac Alert: Lid closed on battery, but active recording or media was detected (" ..
                       recordingDetail .. "). System sleep is prevented."
      sendIMessageAlert(alertMsg)
    end
  end
end

-- Periodic watchdog running while in bag scenario (checks every 60s)
local function runWatchdogCheck()
  -- Performance safeguard: if user interacted with the Mac within the last 3 minutes,
  -- this CANNOT be an unattended bag scenario. Skip immediately without further checks.
  local idleTime = hs.host.idleTime()
  if idleTime < 180 then
    highCpuCount = 0
    return
  end

  if not isBagScenario() then
    highCpuCount = 0
    return
  end

  local usage = hs.host.cpuUsage()
  local activeCpu = (usage and usage.overall and usage.overall.active) or 0

  if activeCpu >= HIGH_CPU_THRESHOLD_PERCENT then
    highCpuCount = highCpuCount + 1
    print(string.format("⚠️ [clamshell_guard] Unattended bag load: %.1f%% CPU (check %d/%d)",
      activeCpu, highCpuCount, HIGH_CPU_CONSECUTIVE_LIMIT))

    if highCpuCount >= HIGH_CPU_CONSECUTIVE_LIMIT then
      highCpuCount = 0
      local emergencyMsg = string.format(
        "🚨 Mac Emergency Sleep: Sustained CPU load (%.1f%%) detected while unattended in your bag. Putting Mac to sleep now to protect battery and hardware.",
        activeCpu
      )
      sendIMessageAlert(emergencyMsg)

      -- Give iMessage dispatch a moment to exit before sleeping system
      hs.timer.doAfter(2.0, function()
        hs.caffeinate.systemSleep()
      end)
    end
  else
    highCpuCount = 0
  end
end

function M.start()
  M.stop()

  -- Watch for screen sleep / lid closure
  activeWatchers.clamshellPowerWatcher = hs.caffeinate.watcher.new(function(eventType)
    if eventType == hs.caffeinate.watcher.screensDidSleep
       or eventType == hs.caffeinate.watcher.screensDidLock then
      -- Give macOS a 2-second grace period for clamshell ioreg and assertions to settle
      hs.timer.doAfter(2.0, checkImmediateLidClose)
    elseif eventType == hs.caffeinate.watcher.screensDidWake
       or eventType == hs.caffeinate.watcher.systemDidWake then
      highCpuCount = 0
    end
  end)
  activeWatchers.clamshellPowerWatcher:start()

  -- Recurring 60-second watchdog timer
  activeWatchers.clamshellTimer = hs.timer.new(60, runWatchdogCheck)
  activeWatchers.clamshellTimer:start()

  print("✓ [clamshell_guard] Module started")
end

function M.stop()
  if activeWatchers.clamshellPowerWatcher then
    activeWatchers.clamshellPowerWatcher:stop()
    activeWatchers.clamshellPowerWatcher = nil
  end
  if activeWatchers.clamshellTimer then
    activeWatchers.clamshellTimer:stop()
    activeWatchers.clamshellTimer = nil
  end
  highCpuCount = 0
end

return M
