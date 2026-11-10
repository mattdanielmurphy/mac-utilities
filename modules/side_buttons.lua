-- ~/.hammerspoon/modules/side_buttons.lua
-- Mouse side buttons do back and forward in every app (replaces SensibleSideButtons).
--
-- The two buttons reach apps as raw buttons 3 and 4, and apps split into two camps
-- (tested 2026-11-01): Chrome and other Chromium apps act on the raw button and ignore a
-- swipe; Finder and most Mac apps ignore the raw button and act on a two-finger swipe.
-- So apps in `apps.native` keep the raw button, and everywhere else the press is swallowed
-- and turned into the same fake swipe SensibleSideButtons posted. Not ⌘[ and ⌘]: those
-- outdent text in code editors, a swipe does nothing where it isn't understood.
--
-- The app is the one under the pointer, since that's where the button lands. It's read from
-- the window list (hs.window.list), never Accessibility: an AX hit test here would switch
-- Chrome's accessibility mode on and slow it down.

-- Feel knobs (⌃⌥⌘T Tweaks panel).
local TWEAKS = {
  ["apps.native"] = { "com.google.Chrome* com.brave.Browser* com.microsoft.edgemac* company.thebrowser.Browser com.microsoft.VSCode* com.todesktop.230313mzl4w4u92 ca.mattmurphy.mattinee*",
    note = "Bundle IDs that handle the side buttons themselves, separated by spaces (* = starts with)" },
  ["buttons.swap"] = { false, note = "Swap back and forward" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Mouse Side Buttons",
  file = require("modules.tweaks").dir .. "/side_buttons.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "side_buttons",
  name = "Mouse Side Buttons (Back/Forward)",
  defaultEnabled = true,
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local BACK, FORWARD = 3, 4 -- mouseEventButtonNumber of the two side buttons

function M.isNative(bundleID, list)
  if not bundleID then return false end
  for entry in (list or ""):gmatch("%S+") do
    if entry:sub(-1) == "*" then
      local prefix = entry:sub(1, -2)
      if bundleID:sub(1, #prefix) == prefix then return true end
    elseif entry == bundleID then
      return true
    end
  end
  return false
end

-- What to do with one button event. `held` remembers which presses were swallowed, so a
-- release is always treated like its press even if the pointer has moved to another app.
-- Returns "pass" (leave the event alone), "drop" (swallow it), or "Left" / "Right" (swallow
-- it and post that swipe). Left is back, as in SensibleSideButtons.
function M.step(held, button, isDown, bundleID, cfg)
  if button ~= BACK and button ~= FORWARD then return "pass" end
  if not isDown then
    if held[button] then
      held[button] = nil
      return "drop"
    end
    return "pass"
  end
  if M.isNative(bundleID, cfg.native) then return "pass" end
  held[button] = true
  local isBack = (button == BACK)
  if cfg.swap then isBack = not isBack end
  return isBack and "Left" or "Right"
end

local function bundleUnderPointer()
  local p = hs.mouse.absolutePosition()
  for _, w in ipairs(hs.window.list() or {}) do
    local b = w.kCGWindowBounds
    if b and w.kCGWindowLayer == 0
      and p.x >= b.X and p.x < b.X + b.Width
      and p.y >= b.Y and p.y < b.Y + b.Height then
      local app = hs.application.applicationForPID(w.kCGWindowOwnerPID)
      return app and app:bundleID()
    end
  end
  local front = hs.application.frontmostApplication()
  return front and front:bundleID()
end

local function postSwipe(direction)
  local new = hs.eventtap.event.newGesture
  new("beginSwipe" .. direction):post()
  new("endSwipe" .. direction):post()
end

function M.start()
  M.stop()
  local types = hs.eventtap.event.types
  local buttonProp = hs.eventtap.event.properties.mouseEventButtonNumber
  local held = {}

  activeWatchers.sideButtonsTap = hs.eventtap.new({ types.otherMouseDown, types.otherMouseUp }, function(event)
    local button = event:getProperty(buttonProp)
    if button ~= BACK and button ~= FORWARD then return false end
    local isDown = event:getType() == types.otherMouseDown
    local bundleID = isDown and bundleUnderPointer() or nil
    local action = M.step(held, button, isDown, bundleID, { native = T("apps.native"), swap = T("buttons.swap") })
    if isDown then M.last = { button = button, app = bundleID, action = action } end
    if action == "pass" then return false end
    if action ~= "drop" then postSwipe(action) end
    return true
  end)
  activeWatchers.sideButtonsTap:start()
end

function M.stop()
  if activeWatchers.sideButtonsTap then
    activeWatchers.sideButtonsTap:stop()
    activeWatchers.sideButtonsTap = nil
  end
end

return M
