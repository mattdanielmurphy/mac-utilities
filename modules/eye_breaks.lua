-- ~/.hammerspoon/modules/eye_breaks.lua
-- Eye-strain and long-session break reminders.
--
--   • 20-20-20: every 20 min of active use, a small top-right alert asks you to
--     look ~20 ft away for 20 s.
--   • Hard break: after 3 h of continuous use, a notification + centered alert
--     asks for a real break, repeating every 30 min.
--   • Escalation: after 6 h, a full-screen dim overlay (click or Escape to
--     dismiss) repeats every 15 min until you step away.
--
-- "Continuous use" resets when the keyboard/mouse is idle for BREAK_RESET
-- seconds, or when the Mac sleeps that long. Toggle it from the ⚙︎ menu.

local M = {
  id = "eye_breaks",
  name = "Eye & Break Reminders (20-20-20)"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

-- ── Settings (edit these, the config auto-reloads) ─────────────────────────────
local CFG = {
  EYE_INTERVAL   = 20 * 60,   -- active seconds between 20-20-20 reminders
  EYE_SHOW       = 20,        -- seconds the eye reminder stays up
  EYE_RESET_IDLE = 60,        -- idle this long counts as having looked away
  BREAK_RESET    = 5 * 60,    -- idle/sleep this long ends a continuous session
  HARD_AFTER     = 3 * 3600,  -- first hard-break nudge
  HARD_REPEAT    = 30 * 60,   -- repeat interval for hard-break nudges
  ESCALATE_AFTER = 6 * 3600,  -- switch to the full-screen overlay
  ESCALATE_REPEAT = 15 * 60,  -- repeat interval for the overlay
  TICK           = 15,        -- poll interval (seconds)
}
M.config = CFG

-- ── State ──────────────────────────────────────────────────────────────────────
local state = {}

local function resetSession(now)
  state.sessionStart = now
  state.lastEye = now
  state.lastHard = nil
  state.lastEscalate = nil
end

local function fmtDuration(secs)
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  if h > 0 then return string.format("%dh %02dm", h, m) end
  return string.format("%dm", m)
end

-- ── UI ─────────────────────────────────────────────────────────────────────────
local eyeStyle = {
  strokeColor = { white = 0, alpha = 0 },
  fillColor = { red = 0.08, green = 0.22, blue = 0.20, alpha = 0.92 },
  textColor = { white = 1, alpha = 0.95 },
  radius = 8,
  textSize = 15,
  atScreenEdge = 2,
  padding = 12
}

local hardStyle = {
  strokeColor = { red = 0.85, green = 0.55, blue = 0.25, alpha = 0.9 },
  strokeWidth = 2,
  fillColor = { white = 0.08, alpha = 0.94 },
  textColor = { white = 1, alpha = 0.97 },
  radius = 10,
  textSize = 22,
  padding = 20
}

function M.showEyeReminder()
  hs.alert.show("👀  20-20-20: look ~20 ft away for 20 seconds", eyeStyle, hs.screen.mainScreen(), CFG.EYE_SHOW)
end

function M.showHardNudge(activeSecs)
  local msg = string.format("🧍  %s at the screen. Time for a real break: stand up, walk, water.", fmtDuration(activeSecs))
  hs.notify.new({ title = "Take a break", informativeText = msg, withdrawAfter = 0 }):send()
  hs.alert.show(msg, hardStyle, hs.screen.mainScreen(), 12)
end

function M.dismissOverlay()
  if activeWatchers.eyeBreaksOverlays then
    for _, c in ipairs(activeWatchers.eyeBreaksOverlays) do c:delete() end
    activeWatchers.eyeBreaksOverlays = nil
  end
  if activeWatchers.eyeBreaksEscKey then
    activeWatchers.eyeBreaksEscKey:delete()
    activeWatchers.eyeBreaksEscKey = nil
  end
end

function M.showEscalation(activeSecs)
  M.dismissOverlay()
  local overlays = {}
  for _, screen in ipairs(hs.screen.allScreens()) do
    local f = screen:fullFrame()
    local c = hs.canvas.new(f)
    c:level(hs.canvas.windowLevels.screenSaver)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c[1] = { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 0.78 } }
    c[2] = {
      type = "text",
      text = string.format("%s without a real break.\n\nStep away from the screen for 10 minutes.", fmtDuration(activeSecs)),
      textSize = 34, textColor = { white = 1, alpha = 0.96 }, textAlignment = "center",
      frame = { x = "10%", y = "38%", w = "80%", h = "20%" }
    }
    c[3] = {
      type = "text",
      text = "Click anywhere or press Escape to dismiss",
      textSize = 15, textColor = { white = 1, alpha = 0.6 }, textAlignment = "center",
      frame = { x = "10%", y = "62%", w = "80%", h = "5%" }
    }
    c:mouseCallback(function() M.dismissOverlay() end)
    c:canvasMouseEvents(true, false, false, false)
    c:show(0.4)
    table.insert(overlays, c)
  end
  activeWatchers.eyeBreaksOverlays = overlays
  activeWatchers.eyeBreaksEscKey = hs.hotkey.bind({}, "escape", function() M.dismissOverlay() end)
  hs.notify.new({ title = "Take a break now", informativeText = fmtDuration(activeSecs) .. " of continuous use.", withdrawAfter = 0 }):send()
end

-- ── Core loop ──────────────────────────────────────────────────────────────────
-- `now` and `idle` can be passed in for testing.
function M.tick(now, idle)
  now = now or os.time()
  idle = idle or hs.host.idleTime()

  -- A long gap between ticks means the Mac was asleep.
  if not state.lastTick or (now - state.lastTick) >= CFG.BREAK_RESET then
    resetSession(now)
  end
  state.lastTick = now

  if idle >= CFG.BREAK_RESET then
    resetSession(now)
    M.dismissOverlay()
    return "reset"
  end

  if idle >= CFG.EYE_RESET_IDLE then
    state.lastEye = now
    return "idle"
  end

  local active = now - state.sessionStart

  if active >= CFG.ESCALATE_AFTER then
    if not state.lastEscalate or (now - state.lastEscalate) >= CFG.ESCALATE_REPEAT then
      state.lastEscalate = now
      state.lastEye = now
      M.showEscalation(active)
      return "escalate"
    end
  elseif active >= CFG.HARD_AFTER then
    if not state.lastHard or (now - state.lastHard) >= CFG.HARD_REPEAT then
      state.lastHard = now
      state.lastEye = now
      M.showHardNudge(active)
      return "hard"
    end
  end

  if (now - state.lastEye) >= CFG.EYE_INTERVAL then
    state.lastEye = now
    M.showEyeReminder()
    return "eye"
  end
  return "ok"
end

function M.status()
  if not state.sessionStart then return "not running" end
  local now = os.time()
  return string.format("continuous: %s, next eye reminder in %s",
    fmtDuration(now - state.sessionStart),
    fmtDuration(math.max(0, CFG.EYE_INTERVAL - (now - state.lastEye))))
end

function M._resetForTest(now)
  state = {}
  state.lastTick = now
  resetSession(now)
end

function M.start()
  M.stop()
  state = {}
  activeWatchers.eyeBreaksTimer = hs.timer.doEvery(CFG.TICK, function()
    local ok, err = pcall(M.tick)
    if not ok then print("eye_breaks tick error: " .. tostring(err)) end
  end)
  M.tick()
end

function M.stop()
  if activeWatchers.eyeBreaksTimer then
    activeWatchers.eyeBreaksTimer:stop()
    activeWatchers.eyeBreaksTimer = nil
  end
  M.dismissOverlay()
end

return M
