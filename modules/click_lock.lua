-- ~/.hammerspoon/modules/click_lock.lua
-- Mouse Click-Lock (Cmd + Option + Left Click locks the mouse down, and clicking again or pressing Escape releases it)

-- Feel knobs (⌃⌥⌘T Tweaks panel); found by bin/tweaks scan, kept by prune.
local TWEAKS = {
  ["look.fillAlpha"] = { 0.75, min = 0, max = 1, step = 0.05, note = "Alert background opacity (0-1)" },
  ["look.textAlpha"] = { 0.85, min = 0.3, max = 1, step = 0.05, note = "Alert text opacity (0-1)" },
  ["look.radius"] = { 4, min = 0, max = 20, step = 1, note = "Alert corner radius in points" },
  ["look.textSize"] = { 12, min = 8, max = 24, step = 1, note = "Alert text size in points" },
  ["look.padding"] = { 8, min = 0, max = 24, step = 1, note = "Space around alert text in points" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Mouse Click-Lock (Cmd+Option+Click)",
  file = require("modules.tweaks").dir .. "/click_lock.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "click_lock",
  name = "Mouse Click-Lock (Cmd+Option+Click)"
}

-- ── Global Anchoring Convention ─────────────────────────────────────────────────
-- All persistent watchers, event taps, and hotkeys in this file are anchored to the
-- global `activeWatchers` table so Lua's garbage collector never reclaims them.
-- ────────────────────────────────────────────────────────────────────────────────

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local isMouseLocked = false
local suppressPhysicalUp = false

local function notifySubtle(message, duration)
  local style = {
    strokeColor = { white = 0, alpha = 0 },
    fillColor = { white = 0, alpha = T("look.fillAlpha") },
    textColor = { white = 1, alpha = T("look.textAlpha") },
    radius = T("look.radius"),
    textSize = T("look.textSize"),
    atScreenEdge = 2, -- Top-right corner
    padding = T("look.padding")
  }
  hs.alert.show(message, style, duration or 1.2)
end

local function stopEscapeTap()
  if activeWatchers.clickLockEscapeTap and activeWatchers.clickLockEscapeTap:isEnabled() then
    activeWatchers.clickLockEscapeTap:stop()
  end
end

local function unlockMouse()
  if isMouseLocked then
    local currentPos = hs.mouse.absolutePosition()
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, currentPos):post()
    isMouseLocked = false
    suppressPhysicalUp = false
    stopEscapeTap()
    notifySubtle("🔓 Click-Lock Released", 1.0)
  end
end

local function startEscapeTap()
  if not activeWatchers.clickLockEscapeTap then
    activeWatchers.clickLockEscapeTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
      if isMouseLocked and event:getKeyCode() == 53 then -- 53 is Escape
        unlockMouse()
        return true
      end
      return false
    end)
  end
  if activeWatchers.clickLockEscapeTap and not activeWatchers.clickLockEscapeTap:isEnabled() then
    activeWatchers.clickLockEscapeTap:start()
  end
end

function M.start()
  M.stop()

  local types = hs.eventtap.event.types

  -- Monitor mouse events for Cmd + Option + Left Click to toggle drag/lock state
  activeWatchers.clickLockTap = hs.eventtap.new({
    types.leftMouseDown,
    types.leftMouseUp,
    types.mouseMoved
  }, function(event)
    local eventType = event:getType()
    local flags = event:getFlags()

    if eventType == types.leftMouseDown then
      if isMouseLocked then
        -- Second click releases the locked mouse button
        local currentPos = hs.mouse.absolutePosition()
        hs.eventtap.event.newMouseEvent(types.leftMouseUp, currentPos):post()
        isMouseLocked = false
        suppressPhysicalUp = true -- Suppress physical release of this second click
        stopEscapeTap()
        notifySubtle("🔓 Click-Lock Released", 1.0)
        return true -- Consume click event
      elseif flags.cmd and flags.alt and not flags.shift and not flags.ctrl then
        -- Cmd + Option + Click initiates the lock
        -- Strip cmd and alt flags so the target application receives a clean leftMouseDown
        flags.cmd = nil
        flags.alt = nil
        event:setFlags(flags)
        isMouseLocked = true
        suppressPhysicalUp = true -- Suppress physical release when finger lifts
        startEscapeTap()
        notifySubtle("🔒 Click-Lock Engaged", 1.0)
        return false -- Pass the modified leftMouseDown through to begin drag/selection
      end

    elseif eventType == types.leftMouseUp then
      if suppressPhysicalUp then
        suppressPhysicalUp = false
        return true -- Consume physical release so mouse button stays logically down
      end

    elseif eventType == types.mouseMoved then
      if isMouseLocked then
        -- Convert mouse motion into leftMouseDragged so apps perform real drag/selection
        event:setType(types.leftMouseDragged)
        -- Strip cmd/alt if user is still lifting fingers so drag isn't treated as option-drag
        local moveFlags = event:getFlags()
        if moveFlags.cmd or moveFlags.alt then
          moveFlags.cmd = nil
          moveFlags.alt = nil
          event:setFlags(moveFlags)
        end
        return false
      end
    end

    return false
  end)

  if activeWatchers.clickLockTap then
    activeWatchers.clickLockTap:start()
  end
end

function M.stop()
  if isMouseLocked then
    unlockMouse()
  end
  stopEscapeTap()
  if activeWatchers.clickLockTap then
    activeWatchers.clickLockTap:stop()
    activeWatchers.clickLockTap = nil
  end
  if activeWatchers.clickLockEscapeTap then
    activeWatchers.clickLockEscapeTap:stop()
    activeWatchers.clickLockEscapeTap = nil
  end
  isMouseLocked = false
  suppressPhysicalUp = false
end

function M.isLocked()
  return isMouseLocked
end

return M
