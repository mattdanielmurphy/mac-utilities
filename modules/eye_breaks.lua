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
    ["eye.countdownTextSize"] = { 22, min = 12, max = 48, step = 1, note = "Font size of the eye-break countdown" },
    ["eye.skipHintTextSize"] = { 14, min = 9, max = 24, step = 1, note = "Font size of the skip hint on the eye wash" },
    ["overlay.dimAlpha"] = { 0.78, min = 0.3, max = 1, step = 0.02, note = "Opacity of the dark full-screen overlay" },
    ["overlay.messageTextSize"] = { 34, min = 18, max = 72, step = 1, note = "Font size of the main message on the full-screen overlay" },
    ["hard.dismissTextSize"] = { 15, min = 10, max = 28, step = 1, note = "Font size of the dismiss hint on the full-screen overlay" },
    ["overlay.hintAlpha"] = { 0.6, min = 0.2, max = 1, step = 0.05, note = "Opacity of the dismiss hint on the overlay" },
    ["wash.fadeIn"]    = { 1.5, min = 0, max = 5, step = 0.1, note = "Seconds to fade to black and white" },
    ["wash.fadeOut"]   = { 0.8, min = 0, max = 3, step = 0.1, note = "Seconds to fade back" },
    ["wash.lightAlpha"] = { 0.9, min = 0.3, max = 1, step = 0.05, note = "Wash opacity in light mode" },
    ["wash.darkAlpha"]  = { 0.9, min = 0.3, max = 1, step = 0.05, note = "Wash opacity in dark mode" },
    ["text.size"]      = { 40, min = 18, max = 80, step = 1, note = "Prompt size (pt)" },
    ["defer.typingQuiet"] = { 4, min = 1, max = 30, step = 1, note = "Hold the eye break until no key pressed for this many seconds" },
    ["defer.dictateQuiet"] = { 6, min = 1, max = 30, step = 1, note = "Hold the eye break until Claude dictation has been off this many seconds (no cap)" },
    ["defer.max"]      = { 120, min = 10, max = 600, step = 10, note = "Longest the eye break waits for typing / read-aloud before showing anyway" },
    ["snooze.after"]   = { 60, min = 10, max = 600, step = 5, note = "Seconds before an early-dismissed eye break comes back" },
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

-- Rest still owed from an early-dismissed eye break (nil = none).
local owed = nil

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

-- Early dismiss = snooze: the break comes back after snooze.after with the rest still owed.
local function snoozeEye(left)
  M.dismissEyeWash()
  owed = left
  if activeWatchers.eyeSnoozeTimer then activeWatchers.eyeSnoozeTimer:stop() end
  activeWatchers.eyeSnoozeTimer = hs.timer.doAfter(T("snooze.after"), function()
    activeWatchers.eyeSnoozeTimer = nil
    M.requestEye()
  end)
end
M._snooze = snoozeEye

function M.showEyeReminder(secs)
  M.dismissEyeWash(true)
  secs = secs or owed or CFG.EYE_SHOW
  owed = nil
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
    c[3] = { type = "text", text = tostring(secs) .. " s", textSize = T("eye.countdownTextSize"), textColor = hex(pal.text, 0.7),
             textAlignment = "center", frame = { x = "10%", y = "52%", w = "80%", h = "6%" } }
    c[4] = { type = "text", text = string.format("Click or Escape = snooze %d s (the rest comes back)", T("snooze.after")), textSize = T("eye.skipHintTextSize"), textColor = hex(pal.text, 0.5),
             textAlignment = "center", frame = { x = "10%", y = "90%", w = "80%", h = "4%" } }
    c:mouseCallback(function() snoozeEye(activeWatchers.eyeWashLeft) end)
    c:canvasMouseEvents(true, false, false, false)
    c:show(T("wash.fadeIn"))
    table.insert(canvases, c)
  end
  activeWatchers.eyeWashCanvases = canvases
  activeWatchers.eyeWashLeft = secs
  activeWatchers.eyeWashKey = hs.hotkey.bind({}, "escape", function() snoozeEye(activeWatchers.eyeWashLeft) end)
  local left = secs
  activeWatchers.eyeWashTimer = hs.timer.doEvery(1, function()
    left = left - 1
    activeWatchers.eyeWashLeft = left
    if left <= 0 then M.dismissEyeWash(); return end
    for _, c in ipairs(canvases) do c[3].text = tostring(left) .. " s" end
  end)
end

-- ── Deferral: wait for typing / read-aloud / dictation to finish ───────────────────────────
local lastKey = 0
local lastDictation = -1e9
-- Swappable for tests.
M._clock = function() return hs.timer.secondsSinceEpoch() end
M._readingAloud = function()
  local ok, ra = pcall(require, "modules.claude_read_aloud")
  return ok and ra.isReading and ra.isReading() or false
end
M._dictating = function()
  local ok, ra = pcall(require, "modules.claude_read_aloud")
  return ok and ra.isDictating and ra.isDictating() or false
end

-- Why the break should wait right now, or nil.
function M.busyReason(now)
  now = now or M._clock()
  if now - lastKey < T("defer.typingQuiet") then return "typing" end
  if M._readingAloud() then return "reading aloud" end
  -- Dictation: hold while the mic is on and for a few seconds after (the mic flickers off
  -- between phrases), with no cap; the eye break never cuts into dictation.
  if M._dictating() then lastDictation = now end
  if now - lastDictation < T("defer.dictateQuiet") then return "dictating" end
  return nil
end

-- Show the eye break once Matt is idle; never wait longer than defer.max.
local pendingSince = nil
function M.requestEye(now)
  now = now or M._clock()
  pendingSince = pendingSince or now
  if activeWatchers.eyeWashCanvases then pendingSince = nil; return "shown" end
  local busy = M.busyReason(now)
  if busy == "dictating" or (busy and now - pendingSince < T("defer.max")) then
    if not activeWatchers.eyeDeferTimer then
      activeWatchers.eyeDeferTimer = hs.timer.doEvery(1, function() M.requestEye() end)
    end
    return "deferred"
  end
  if activeWatchers.eyeDeferTimer then activeWatchers.eyeDeferTimer:stop(); activeWatchers.eyeDeferTimer = nil end
  pendingSince = nil
  M.showEyeReminder()
  return "shown"
end

function M._noteKey(t) lastKey = t or M._clock() end
function M._owed() return owed end

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
    c[1] = { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = T("overlay.dimAlpha") } }
    c[2] = {
      type = "text",
      text = string.format("%s without a real break.\n\nStep away from the screen for 10 minutes.", fmtDuration(activeSecs)),
      textSize = T("overlay.messageTextSize"), textColor = { white = 1, alpha = 0.96 }, textAlignment = "center",
      frame = { x = "10%", y = "38%", w = "80%", h = "20%" }
    }
    c[3] = {
      type = "text",
      text = "Click anywhere or press Escape to dismiss",
      textSize = T("hard.dismissTextSize"), textColor = { white = 1, alpha = T("overlay.hintAlpha") }, textAlignment = "center",
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
    M.requestEye()
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
  -- Passive listener: only notes when a key was pressed, never blocks or posts input.
  activeWatchers.eyeKeyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function() lastKey = M._clock(); return false end)
  activeWatchers.eyeKeyTap:start()
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
  for _, k in ipairs({ "eyeDeferTimer", "eyeSnoozeTimer", "eyeKeyTap" }) do
    if activeWatchers[k] then activeWatchers[k]:stop(); activeWatchers[k] = nil end
  end
  pendingSince = nil
end

return M
