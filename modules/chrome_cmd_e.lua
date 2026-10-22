-- Google Chrome Cmd-E remap.
-- Kept as a separate, explicitly disabled module so it remains visible and
-- independently controllable from the Hammerspoon menu.

local M = {
  id = "chrome_cmd_e",
  name = "Chrome: Cmd-E → Cmd-Option-G",
  defaultEnabled = false
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers
local chromeBundleID = "com.google.Chrome"

function M.start()
  M.stop()

  activeWatchers.chromeCmdEHotkey = hs.hotkey.new({"cmd"}, "e", function()
    hs.eventtap.keyStroke({"cmd", "alt"}, "g")
  end)

  local function setEnabledForApp(appName, app)
    local isChrome = app and (app:bundleID() == chromeBundleID or appName == "Google Chrome")
    if activeWatchers.chromeCmdEHotkey then
      if isChrome then
        activeWatchers.chromeCmdEHotkey:enable()
      else
        activeWatchers.chromeCmdEHotkey:disable()
      end
    end
  end

  activeWatchers.chromeCmdEWatcher = hs.application.watcher.new(function(appName, eventType, app)
    if eventType == hs.application.watcher.activated or eventType == hs.application.watcher.deactivated then
      setEnabledForApp(appName, app)
    end
  end)
  activeWatchers.chromeCmdEWatcher:start()

  local frontApp = hs.application.frontmostApplication()
  if frontApp then
    setEnabledForApp(frontApp:name(), frontApp)
  end
end

function M.stop()
  if activeWatchers.chromeCmdEHotkey then
    activeWatchers.chromeCmdEHotkey:disable()
    activeWatchers.chromeCmdEHotkey:delete()
    activeWatchers.chromeCmdEHotkey = nil
  end
  if activeWatchers.chromeCmdEWatcher then
    activeWatchers.chromeCmdEWatcher:stop()
    activeWatchers.chromeCmdEWatcher = nil
  end
end

return M
