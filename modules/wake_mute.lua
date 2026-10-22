-- ~/.hammerspoon/modules/wake_mute.lua
-- Mutes macOS audio output device ONLY when the machine has been asleep or locked
-- for more than 10 minutes, preventing accidental audio playback in classrooms
-- while avoiding annoying muting during short breaks or routine laptop use.

local M = {
  id = "wake_mute",
  name = "Mute Audio on Sleep & Wake (>10m)"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

-- Mute threshold: 10 minutes
local MUTE_THRESHOLD_SECONDS = 10 * 60

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

        if elapsed >= MUTE_THRESHOLD_SECONDS then
          local mins = math.floor(elapsed / 60)
          muteAudio(string.format("Asleep/Locked for %dm", mins))
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
  if activeWatchers.wakeMuteWatcher then
    activeWatchers.wakeMuteWatcher:stop()
    activeWatchers.wakeMuteWatcher = nil
  end
  sleepOrLockTime = nil
end

return M
