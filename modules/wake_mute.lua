-- ~/.hammerspoon/modules/wake_mute.lua
-- Mutes macOS audio output device ONLY when the machine has been asleep or locked
-- for more than 10 minutes, preventing accidental audio playback in classrooms
-- while avoiding annoying muting during short breaks or routine laptop use.
-- Skipped at home (Matt, 2026-10-25): home = home Wi-Fi, or the hotspot with home in
-- range (modules/wifi_home.lua). Wi-Fi is often still joining right after wake, so an
-- unknown network is re-checked for a few seconds; still unknown → mute (the safe side).

-- Feel knobs (⌃⌥⌘T Tweaks panel); found by bin/tweaks scan, kept by prune.
local TWEAKS = {
  ["timing.muteThresholdMinutes"] = { 10 * 60, min = 60, max = 3600, step = 30, note = "Seconds asleep or locked before wake auto-mutes" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Mute Audio on Sleep & Wake (>10m)",
  file = require("modules.tweaks").dir .. "/wake_mute.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "wake_mute",
  name = "Mute Audio on Sleep & Wake (>10m)"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

-- Mute threshold: 10 minutes

local sleepOrLockTime = nil

local function muteAudio(reason)
  local dev = hs.audiodevice.defaultOutputDevice()
  local didMute = false

  if dev and not dev:muted() then
    dev:setMuted(true)
    didMute = true
  end

  -- Extra safeguard: ensure built-in speakers are also muted in case headphones disconnect
  local internal = hs.audiodevice.findOutputByName("MacBook Pro Speakers")
  if internal and internal ~= dev and not internal:muted() then
    internal:setMuted(true)
    didMute = true
  end

  if didMute then
    hs.alert.closeAll()
    hs.alert.show("🔇 Audio Muted (" .. reason .. ")", 2.0)
  end
end

-- Mute unless at home. Retries while the network is unknown (nil SSID).
local SSID_RETRIES, SSID_RETRY_SECONDS = 6, 2
local function muteUnlessHome(reason, tries)
  tries = tries or 0
  require("modules.wifi_home").atHome(function(atHome, ssid)
    if atHome then
      print("wake_mute: at home (" .. tostring(ssid) .. "), not muting")
    elseif ssid == nil and tries < SSID_RETRIES then
      activeWatchers.wakeMuteRetry = hs.timer.doAfter(SSID_RETRY_SECONDS, function()
        muteUnlessHome(reason, tries + 1)
      end)
    else
      muteAudio(reason)
    end
  end)
end
M.muteUnlessHome = muteUnlessHome

function M.start()
  M.stop()

  activeWatchers.wakeMuteWatcher = hs.caffeinate.watcher.new(function(eventType)
    -- System going to sleep or screen locking/sleeping
    if eventType == hs.caffeinate.watcher.systemWillSleep
       or eventType == hs.caffeinate.watcher.screensDidSleep
       or eventType == hs.caffeinate.watcher.screensDidLock
       or eventType == hs.caffeinate.watcher.sessionDidResignActive then
      if not sleepOrLockTime then
        sleepOrLockTime = os.time()
      end

    -- System waking or screen waking/unlocking
    elseif eventType == hs.caffeinate.watcher.systemDidWake
       or eventType == hs.caffeinate.watcher.screensDidWake
       or eventType == hs.caffeinate.watcher.screensDidUnlock
       or eventType == hs.caffeinate.watcher.sessionDidBecomeActive then
      if sleepOrLockTime then
        local elapsed = os.time() - sleepOrLockTime

        if elapsed >= T("timing.muteThresholdMinutes") then
          local mins = math.floor(elapsed / 60)
          muteUnlessHome(string.format("Asleep/Locked for %dm", mins))
          sleepOrLockTime = nil
        elseif eventType == hs.caffeinate.watcher.screensDidUnlock
            or eventType == hs.caffeinate.watcher.sessionDidBecomeActive
            or eventType == hs.caffeinate.watcher.systemDidWake then
          -- Once unlocked or system woke before 10 minutes, clear tracking
          sleepOrLockTime = nil
        end
      end
    end
  end)

  activeWatchers.wakeMuteWatcher:start()
end

function M.stop()
  if activeWatchers.wakeMuteRetry then
    activeWatchers.wakeMuteRetry:stop()
    activeWatchers.wakeMuteRetry = nil
  end
  if activeWatchers.wakeMuteWatcher then
    activeWatchers.wakeMuteWatcher:stop()
    activeWatchers.wakeMuteWatcher = nil
  end
  sleepOrLockTime = nil
end

return M
