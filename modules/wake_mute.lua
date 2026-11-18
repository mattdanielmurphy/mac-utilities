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

-- Mutes the default output and the built-in speakers (in case headphones come out) through the
-- bin/audio-devices helper, never hs.audiodevice: wake is exactly when coreaudiod is slowest, and
-- a stuck Core Audio call here would freeze the keyboard (2026-11-15).
local function muteAudio(reason)
  require("modules.audio_events").run({ "--mute-outputs" }, function(out)
    if out and out:find("muted", 1, true) then
      hs.alert.closeAll()
      hs.alert.show("🔇 Audio Muted (" .. reason .. ")", 2.0)
    end
  end, 15)
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
