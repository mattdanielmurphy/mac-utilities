local M = {
  id = "cloud_mounter_guard",
  name = "CloudMounter Upgrade Popup Guard"
}

-- ── Global Anchoring Convention ─────────────────────────────────────────────────
-- All persistent watchers, filters, and hotkeys in this file are anchored to the
-- global `activeWatchers` table (defined in init.lua) so Lua's garbage collector
-- never silently reclaims them. Local variables are NOT safe for these resources.
-- Do NOT add timer-based health checks — the root cause is always a missing global
-- reference, not a runtime glitch.
-- ────────────────────────────────────────────────────────────────────────────────

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

function M.start()
  M.stop()

  -- ── Subtle Notification Helper ──────────────────────────────────────────────────
  local function notifySubtle(message, duration)
    local style = {
      strokeColor = { white = 0, alpha = 0 },
      fillColor = { white = 0, alpha = 0.75 },
      textColor = { white = 1, alpha = 0.85 },
      radius = 4,
      textSize = 12,
      atScreenEdge = 2, -- Top-right corner
      padding = 8
    }
    hs.alert.show(message, style, duration or 1.5)
  end

  -- ── 3. Auto-dismiss CloudMounter Upgrade Popup (Focus-Preserving) ────────────────
  -- Watches CloudMounter's own windows only. (It used an hs.window.filter that
  -- tracked every window of every app through accessibility: slow to set up on
  -- each reload and a main-thread stall whenever any app was busy.)
  local CM_BUNDLE = "com.eltima.cloudmounter"

  local function onWindow(win)
    local title = win:title()
    local subrole = win:subrole()
    if title == "Upgrade to PRO version required!" or (subrole == "AXDialog" and (title == "" or title == "Window")) then
      hs.timer.doAfter(0.05, function()
        -- Runs on its own, so it takes the shared input queue (claude_control):
        -- this Escape never lands in the middle of an agent's or another automation's input.
        local function dismiss()
          local app = win:application()
          if app then
            hs.eventtap.keyStroke({}, "escape", 0, app)
          end
          notifySubtle("⚡️ CloudMounter PRO nag auto-dismissed", 1.5)
        end
        if claudeControl and claudeControl.withInput then
          claudeControl.withInput("CloudMounter nag dismiss", dismiss)
        else
          dismiss()
        end
      end)
    end
  end

  local function watchCloudMounter(app)
    if activeWatchers.cloudMounterWatcher then activeWatchers.cloudMounterWatcher:stop() end
    activeWatchers.cloudMounterWatcher = nil
    if not app then return end
    activeWatchers.cloudMounterWatcher = app:newWatcher(function(win, event)
      if event == hs.uielement.watcher.windowCreated then onWindow(win) end
    end)
    activeWatchers.cloudMounterWatcher:start({ hs.uielement.watcher.windowCreated })
  end

  activeWatchers.cloudMounterApps = hs.application.watcher.new(function(_, event, app)
    if app and app:bundleID() == CM_BUNDLE then
      if event == hs.application.watcher.launched then watchCloudMounter(app)
      elseif event == hs.application.watcher.terminated then watchCloudMounter(nil) end
    end
  end)
  activeWatchers.cloudMounterApps:start()
  watchCloudMounter(hs.application.applicationsForBundleID(CM_BUNDLE)[1])
end

function M.stop()
  for _, k in ipairs({ "cloudMounterWatcher", "cloudMounterApps" }) do
    if activeWatchers[k] then activeWatchers[k]:stop(); activeWatchers[k] = nil end
  end
end

return M
