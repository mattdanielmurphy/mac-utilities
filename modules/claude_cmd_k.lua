-- Claude desktop app Cmd-K → project-filtered palette.
-- Cmd-K opens Claude's Cmd-K palette, types `project:` and presses Enter so the
-- list filters to the current ("Everything") project. Cmd-Shift-K gives the
-- plain, unfiltered Cmd-K. The tap only runs while Claude is frontmost.
--
-- Uses an eventtap rather than hs.hotkey: synthetic Cmd-K events we post are
-- tagged via eventSourceUserData and passed through, so they can never
-- re-trigger the handler (hs.hotkey disable/enable around keyStroke raced and
-- looped, since the posted event arrives after the hotkey is re-enabled).

local M = {
  id = "claude_cmd_k",
  name = "Claude: Cmd-K → project: filter",
  defaultEnabled = true
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers
local claudeBundleID = "com.anthropic.claudefordesktop"
local T

local PALETTE_DELAY = 0.25 -- wait for the palette to open before typing
local ENTER_DELAY = 0.15   -- wait for the typed filter to register
local MARK = 0x434B4B      -- "CKK": tags events this module posts

local types = hs.eventtap.event.types
local props = hs.eventtap.event.properties
local kCode = hs.keycodes.map.k

local function post(mods, key)
  for _, down in ipairs({true, false}) do
    local ev = hs.eventtap.event.newKeyEvent(mods, key, down)
    ev:setProperty(props.eventSourceUserData, MARK)
    ev:post()
  end
end

local function sendRealCmdK()
  post({"cmd"}, "k")
end

local function openProjectFiltered()
  sendRealCmdK()
  hs.timer.doAfter(PALETTE_DELAY, function()
    hs.eventtap.keyStrokes(T("palette.filter"))
    hs.timer.doAfter(ENTER_DELAY, function()
      post({}, "return")
    end)
  end)
end

local function handleKey(ev)
  if ev:getKeyCode() ~= kCode then return false end
  if ev:getProperty(props.eventSourceUserData) == MARK then return false end
  local f = ev:getFlags()
  if not f.cmd or f.alt or f.ctrl or f.fn then return false end
  -- Defer work out of the tap callback; swallow the physical keystroke.
  if T("palette.filter") == "" then return false end -- no filter set: plain Cmd-K
  if f.shift then
    hs.timer.doAfter(0, sendRealCmdK)
  else
    hs.timer.doAfter(0, openProjectFiltered)
  end
  return true
end

local function setActive(app)
  local tap = activeWatchers.claudeCmdKTap
  if not tap then return end
  if app and app:bundleID() == claudeBundleID then
    if not tap:isEnabled() then tap:start() end
  elseif tap:isEnabled() then
    tap:stop()
  end
end

function M.start()
  M.stop()
  local tweaks = require("modules.tweaks")
  T = T or tweaks.open{
    app = "Claude Cmd-K",
    file = tweaks.dir .. "/claude_cmd_k.json",
    knobs = {
      ["palette.filter"] = { "project:", note = "Typed after Cmd-K (e.g. project:). Empty = plain Cmd-K" },
    },
  }

  activeWatchers.claudeCmdKTap = hs.eventtap.new({types.keyDown}, handleKey)

  activeWatchers.claudeCmdKWatcher = hs.application.watcher.new(function(_, eventType, app)
    if eventType == hs.application.watcher.activated then
      setActive(app)
    elseif eventType == hs.application.watcher.deactivated then
      setActive(hs.application.frontmostApplication())
    end
  end)
  activeWatchers.claudeCmdKWatcher:start()

  setActive(hs.application.frontmostApplication())
end

function M.stop()
  if activeWatchers.claudeCmdKTap then
    activeWatchers.claudeCmdKTap:stop()
    activeWatchers.claudeCmdKTap = nil
  end
  if activeWatchers.claudeCmdKWatcher then
    activeWatchers.claudeCmdKWatcher:stop()
    activeWatchers.claudeCmdKWatcher = nil
  end
end

return M
