-- ~/.hammerspoon/modules/bt_mic_guard.lua
-- Keeps Bluetooth headphones out of phone-call mode. macOS makes AirPods and Sonys the default mic
-- each time they connect; the first app to open the default mic then drops them to 24 kHz mono, and
-- they stay there until the default mic moves. So the default mic moves to the Mac's own, and the
-- headphones keep playing in full quality (Matt, 2026-11-02). Apps can still pick the headset mic
-- themselves; a call that does that gets call-quality audio until it ends.
-- Turn it off with guard.enabled in the Tweaks panel (⌃⌥⌘T) to use the headset mic as the default.

local TWEAKS = {
  ["guard.enabled"] = { 1, min = 0, max = 1, step = 1, note = "1 keeps the default mic off Bluetooth headphones; 0 leaves it alone" },
  ["guard.safetyEvery"] = { 300, min = 60, max = 3600, step = 60, note = "Seconds between safety checks; device changes are caught at once by the audio watcher" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Bluetooth Mic Guard",
  file = require("modules.tweaks").dir .. "/bt_mic_guard.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "bt_mic_guard",
  name = "Keep Headphones Out of Call Mode"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

-- All Core Audio work runs in bin/audio-devices, a separate process (2026-11-15: a Core Audio call
-- here froze the keyboard for 60 s while coreaudiod was busy). Checks run when the default mic or
-- the device list changes, plus a slow safety check.
local audio = require("modules.audio_events")
local busy = false

-- Bluetooth default mic → built-in mic. Uses the helper's last report; never blocks.
function M.check()
  if T("guard.enabled") == 0 or busy then return false end
  local s = audio.state()
  if s and s.inTransport ~= "bluetooth" then return false end
  busy = true
  audio.run({ "--unbluetooth-input" }, function(out)
    busy = false
    local from, to = tostring(out or ""):match("^moved\t([^\t]*)\t([^\n]*)")
    if from then print("bt_mic_guard: default mic moved from " .. from .. " to " .. to)
    elseif out == nil then print("bt_mic_guard: Core Audio didn't answer in 10 s; will retry on the next change") end
  end, 10)
  return true
end

local function soon()
  if activeWatchers.btMicGuardSoon then activeWatchers.btMicGuardSoon:stop() end
  activeWatchers.btMicGuardSoon = hs.timer.doAfter(0.5, function() activeWatchers.btMicGuardSoon = nil; M.check() end)
end

function M.start()
  M.stop()
  M.sub = audio.on(function(event) if event == "dIn " or event == "dev#" then soon() end end)
  activeWatchers.btMicGuard = hs.timer.doEvery(T("guard.safetyEvery"), M.check)
  M.check()
end

function M.stop()
  audio.off(M.sub); M.sub = nil
  for _, k in ipairs({ "btMicGuard", "btMicGuardSoon" }) do
    if activeWatchers[k] then activeWatchers[k]:stop(); activeWatchers[k] = nil end
  end
end

function M.status()
  return activeWatchers.btMicGuard ~= nil
end

return M
