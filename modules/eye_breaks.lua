-- ~/.hammerspoon/modules/eye_breaks.lua
-- Eye-strain and long-session break reminders.
--
--   • 20-20-20: every 20 min of active use, the screen fades to black and white
--     with a prompt in the centre to look ~20 ft away for 20 s.
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
local hardStyle = {
  strokeColor = { red = 0.85, green = 0.55, blue = 0.25, alpha = 0.9 },
  strokeWidth = 2,
  fillColor = { white = 0.08, alpha = 0.94 },
  textColor = { white = 1, alpha = 0.97 },
  radius = 10,
  textSize = 22,
  padding = 20
}

-- Eye reminder: the whole screen fades to a neutral black-and-white wash with the prompt
-- in the centre and a countdown. Colours are the Apothecary neutrals from the candidate
-- palette (ai-os design/candidates/directions.json), light or dark to match the system.
-- Feel knobs: ~/.hammerspoon/tweaks/eye_breaks.json, or the Tweaks panel (⌃⌥⌘T).
local T = require("modules.tweaks").open{
  app = "Eye breaks",
  file = require("modules.tweaks").dir .. "/eye_breaks.json",
  knobs = {
    ["wash.fadeIn"]    = { 1.5, min = 0, max = 5, step = 0.1, note = "Seconds to fade to black and white" },
    ["wash.fadeOut"]   = { 0.8, min = 0, max = 3, step = 0.1, note = "Seconds to fade back" },
    ["wash.lightAlpha"] = { 0.9, min = 0.3, max = 1, step = 0.05, note = "Wash opacity in light mode" },
    ["wash.darkAlpha"]  = { 0.9, min = 0.3, max = 1, step = 0.05, note = "Wash opacity in dark mode" },
    ["text.size"]      = { 40, min = 18, max = 80, step = 1, note = "Prompt size (pt)" },
  },
}

local PALETTE = {
  light = { bg = "#f8f8f7", text = "#35322b" },
  dark  = { bg = "#1a1916", text = "#d7d5d1" },
}

local function hex(h, alpha)
  local r, g, b = h:match("#(%x%x)(%x%x)(%x%x)")
  return { red = tonumber(r, 16) / 255, green = tonumber(g, 16) / 255, blue = tonumber(b, 16) / 255, alpha = alpha or 1 }
end

function M.dismissEyeWash(instant)
  if activeWatchers.eyeWashTimer then activeWatchers.eyeWashTimer:stop(); activeWatchers.eyeWashTimer = nil end
  if activeWatchers.eyeWashKey then activeWatchers.eyeWashKey:delete(); activeWatchers.eyeWashKey = nil end
  local cs = activeWatchers.eyeWashCanvases
  activeWatchers.eyeWashCanvases = nil
  if not cs then return end
  for _, c in ipairs(cs) do
    if instant then c:delete() else c:hide(T("wash.fadeOut")); hs.timer.doAfter(T("wash.fadeOut") + 0.2, function() c:delete() end) end
  end
end

function M.showEyeReminder()
  M.dismissEyeWash(true)
  local dark = hs.host.interfaceStyle() == "Dark"
  local pal = dark and PALETTE.dark or PALETTE.light
  local alpha = dark and T("wash.darkAlpha") or T("wash.lightAlpha")
  local canvases = {}
  for _, screen in ipairs(hs.screen.allScreens()) do
    local c = hs.canvas.new(screen:fullFrame())
    c:level(hs.canvas.windowLevels.screenSaver)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c[1] = { type = "rectangle", action = "fill", fillColor = hex(pal.bg, alpha) }
    c[2] = { type = "text", text = "Look 20 feet away", textSize = T("text.size"), textColor = hex(pal.text),
             textAlignment = "center", frame = { x = "10%", y = "40%", w = "80%", h = "10%" } }
    c[3] = { type = "text", text = tostring(CFG.EYE_SHOW) .. " s", textSize = 22, textColor = hex(pal.text, 0.7),
             textAlignment = "center", frame = { x = "10%", y = "52%", w = "80%", h = "6%" } }
    c[4] = { type = "text", text = "Click or press Escape to skip", textSize = 14, textColor = hex(pal.text, 0.5),
             textAlignment = "center", frame = { x = "10%", y = "90%", w = "80%", h = "4%" } }
    c:mouseCallback(function() M.dismissEyeWash() end)
    c:canvasMouseEvents(true, false, false, false)
    c:show(T("wash.fadeIn"))
    table.insert(canvases, c)
  end
  activeWatchers.eyeWashCanvases = canvases
  activeWatchers.eyeWashKey = hs.hotkey.bind({}, "escape", function() M.dismissEyeWash() end)
  local left = CFG.EYE_SHOW
  activeWatchers.eyeWashTimer = hs.timer.doEvery(1, function()
    left = left - 1
    if left <= 0 then M.dismissEyeWash(); return end
    for _, c in ipairs(canvases) do c[3].text = tostring(left) .. " s" end
  end)
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
