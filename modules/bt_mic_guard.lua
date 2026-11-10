-- ~/.hammerspoon/modules/bt_mic_guard.lua
-- Keeps Bluetooth headphones out of phone-call mode. macOS makes AirPods and Sonys the default mic
-- each time they connect; the first app to open the default mic then drops them to 24 kHz mono, and
-- they stay there until the default mic moves. So the default mic moves to the Mac's own, and the
-- headphones keep playing in full quality (Matt, 2026-11-02). Apps can still pick the headset mic
-- themselves; a call that does that gets call-quality audio until it ends.
-- Turn it off with guard.enabled in the Tweaks panel (⌃⌥⌘T) to use the headset mic as the default.

local TWEAKS = {
  ["guard.enabled"] = { 1, min = 0, max = 1, step = 1, note = "1 keeps the default mic off Bluetooth headphones; 0 leaves it alone" },
  ["guard.every"] = { 2, min = 1, max = 30, step = 1, note = "Seconds between checks (read when the module starts)" },
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

-- The Mac's own mic, or nil when there isn't one.
local function builtInMic()
  for _, dev in ipairs(hs.audiodevice.allInputDevices()) do
    if dev:transportType() == "Built-in" then return dev end
  end
end

function M.check()
  if T("guard.enabled") == 0 then return false end
  local current = hs.audiodevice.defaultInputDevice()
  if not current or current:transportType() ~= "Bluetooth" then return false end
  local mic = builtInMic()
  if not mic or not mic:setDefaultInputDevice() then return false end
  print("bt_mic_guard: default mic moved from " .. tostring(current:name()) .. " to " .. tostring(mic:name()))
  return true
end

function M.start()
  M.stop()
  activeWatchers.btMicGuard = hs.timer.doEvery(T("guard.every"), M.check)
  M.check()
end

function M.stop()
  if activeWatchers.btMicGuard then activeWatchers.btMicGuard:stop(); activeWatchers.btMicGuard = nil end
end

function M.status()
  return activeWatchers.btMicGuard ~= nil
end

return M
