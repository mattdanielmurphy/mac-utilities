-- Runaway synthetic-input guard.
-- Every scripted keystroke (Hammerspoon, computer-use agents, osascript,
-- cliclick, anything that posts CGEvents) carries the poster's PID; real
-- keyboard input carries PID 0. This tap rate-limits the scripted ones so a
-- looping script can never spam Enter / text into an app:
--   * more than RETURN_MAX scripted Returns in RETURN_WINDOW seconds, or
--   * more than CHAR_MAX scripted characters in CHAR_WINDOW seconds
-- trips the breaker. While tripped, ALL scripted key presses are dropped
-- (real typing is untouched) until COOLDOWN seconds pass with no scripted
-- key attempts, or the module is toggled off/on from the Hammerspoon menu.
-- The callback only reads event properties and counts; no AX or IPC work.

-- Feel knobs (⌃⌥⌘T Tweaks panel); found by bin/tweaks scan, kept by prune.
local TWEAKS = {
  ["breaker.returnMax"] = { 4, min = 1, max = 15, step = 1, note = "Scripted Returns allowed per window before the breaker trips" },
  ["breaker.returnWindow"] = { 20, min = 5, max = 120, step = 5, note = "Seconds over which scripted Returns are counted" },
  ["breaker.charMax"] = { 300, min = 100, max = 1000, step = 25, note = "Scripted characters allowed per window before the breaker trips" },
  ["breaker.charWindow"] = { 10, min = 3, max = 60, step = 1, note = "Seconds over which scripted characters are counted" },
  ["breaker.cooldown"] = { 300, min = 30, max = 1800, step = 30, note = "Seconds of quiet before the breaker resets itself" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Runaway typing guard (scripted keys)",
  file = require("modules.tweaks").dir .. "/input_guard.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "input_guard",
  name = "Runaway typing guard (scripted keys)",
  defaultEnabled = true
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local CFG = {
  RETURN_MAX = T("breaker.returnMax"),      -- scripted Returns allowed per window
  RETURN_WINDOW = T("breaker.returnWindow"),  -- seconds
  CHAR_MAX = T("breaker.charMax"),      -- scripted characters allowed per window
  CHAR_WINDOW = T("breaker.charWindow"),    -- seconds
  COOLDOWN = T("breaker.cooldown"),      -- seconds of quiet before the breaker resets itself
}
M.CFG = CFG

local types = hs.eventtap.event.types
local props = hs.eventtap.event.properties
local RETURN_CODES = { [36] = true, [76] = true } -- return, keypad enter

local returns, chars = {}, {} -- ring of {t, n}
M.trippedAt = nil
M.lastBlocked = nil
M.stats = { real = 0, scripted = 0, blocked = 0, trips = 0, byPid = {} }
M.lastTrip = nil

local function prune(list, now, window)
  local i = 1
  while list[i] and now - list[i][1] > window do i = i + 1 end
  if i > 1 then
    for _ = 1, i - 1 do table.remove(list, 1) end
  end
end

local function sum(list)
  local s = 0
  for _, e in ipairs(list) do s = s + e[2] end
  return s
end

local function trip(reason, pid)
  M.trippedAt = hs.timer.secondsSinceEpoch()
  M.stats.trips = M.stats.trips + 1
  local who = "pid " .. tostring(pid)
  local app = hs.application.applicationForPID(pid)
  if app then who = app:name() .. " (" .. who .. ")" end
  local msg = "Blocked runaway scripted typing from " .. who .. ": " .. reason
  M.lastTrip = os.date("%H:%M:%S ") .. msg
  print("🛑 input_guard: " .. msg)
  hs.timer.doAfter(0, function()
    hs.alert.show("🛑 " .. msg .. "\nScripted keys are blocked. Toggle \"" .. M.name ..
      "\" in the Hammerspoon menu to reset.", 8)
    hs.notify.new({ title = "Runaway typing blocked", informativeText = msg, withdrawAfter = 0 }):send()
  end)
end

function M.reset()
  M.trippedAt, M.lastBlocked = nil, nil
  returns, chars = {}, {}
end

-- Exposed for tests: returns true if the event should be dropped.
function M.check(pid, keyCode, nChars, now)
  if pid == 0 then
    M.stats.real = M.stats.real + 1
    return false
  end
  M.stats.scripted = M.stats.scripted + 1
  M.stats.byPid[pid] = (M.stats.byPid[pid] or 0) + 1

  if M.trippedAt then
    if now - (M.lastBlocked or M.trippedAt) > CFG.COOLDOWN then
      print("✓ input_guard: cooldown passed, scripted keys allowed again")
      M.reset()
    else
      M.lastBlocked = now
      M.stats.blocked = M.stats.blocked + 1
      return true
    end
  end

  prune(returns, now, CFG.RETURN_WINDOW)
  prune(chars, now, CFG.CHAR_WINDOW)
  if RETURN_CODES[keyCode] then table.insert(returns, { now, 1 }) end
  table.insert(chars, { now, math.max(nChars, 1) })

  if #returns > CFG.RETURN_MAX then
    trip(#returns .. " Enters in " .. CFG.RETURN_WINDOW .. "s", pid)
  elseif sum(chars) > CFG.CHAR_MAX then
    trip(sum(chars) .. " characters in " .. CFG.CHAR_WINDOW .. "s", pid)
  end
  if M.trippedAt then
    M.lastBlocked = now
    M.stats.blocked = M.stats.blocked + 1
    return true
  end
  return false
end

local function onKey(ev)
  local pid = ev:getProperty(props.eventSourceUnixProcessID)
  local nChars = 1
  if pid ~= 0 then nChars = utf8.len(ev:getCharacters(true) or "") or 1 end
  return M.check(pid, ev:getKeyCode(), nChars, hs.timer.secondsSinceEpoch())
end

function M.start()
  M.stop()
  M.reset()
  activeWatchers.inputGuardTap = hs.eventtap.new({ types.keyDown }, onKey)
  activeWatchers.inputGuardTap:start()
end

function M.stop()
  if activeWatchers.inputGuardTap then
    activeWatchers.inputGuardTap:stop()
    activeWatchers.inputGuardTap = nil
  end
  M.reset()
end

return M
