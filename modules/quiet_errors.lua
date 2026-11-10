-- modules/quiet_errors.lua
-- Keeps Hammerspoon out of sight: config errors go to a log file and a quiet notification
-- instead of popping the console, and the console never floats on top.
-- In shared mode (Slub Utils) the Dock and menu bar icons are hidden too; the ⚙︎ menu is the only face.
-- Log: ~/.hammerspoon/logs/errors.log. The console is still in ⚙︎ › Hammerspoon › Console.

local M = {}
local LOG_DIR = os.getenv("HOME") .. "/.hammerspoon/logs"
M.logFile = LOG_DIR .. "/errors.log"

function M.log(err)
  hs.fs.mkdir(LOG_DIR)
  local f = io.open(M.logFile, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S  "), tostring(err), "\n\n"); f:close() end
end

function M.install(shared)
  hs.consoleOnTop(false)
  hs.showError = function(err)
    print(err)
    M.log(err)
    hs.notify.new({ title = "Utilities hit an error", informativeText = "Details in ~/.hammerspoon/logs/errors.log",
      withdrawAfter = 8 }):send()
  end
  if shared then
    hs.menuIcon(false)
    hs.dockicon.hide()
  end
end

return M
