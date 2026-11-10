-- ~/.hammerspoon/modules/tv_brightness.lua
-- The keyboard brightness keys move the TV as well as the laptop screen, so the TV no
-- longer needs Control Center.
--
-- The keys arrive as NX_SYSDEFINED events (same tap pattern as fade_skip), from the Mac
-- keyboard and, through Karabiner, the Logitech one. The tap only listens: every event
-- passes on to macOS, so the laptop screen keeps working as it always has, and with no TV
-- connected nothing here does anything.
--
-- The TV's level is the one Control Center's slider sets (DisplayServices, which is what
-- hs.screen's get/setBrightness use on Apple Silicon). It's read fresh before a press, so
-- a change on the slider is respected. Presses land on the same grid as macOS (16 steps,
-- 64 with ⌥⇧) and glide there over a fraction of a second. Holding repeats on its own
-- timer rather than macOS's, and stops at the top or bottom.
--
-- ⌥ alone is left out: on a brightness key it opens Displays settings.
-- M.log keeps the last 40 key events, for checking how each keyboard's keys arrive here.

-- Feel knobs (⌃⌥⌘T Tweaks panel).
local TWEAKS = {
  ["display.nameContains"] = { "TV", note = "Which screen the keys also move (part of its name; empty = any external screen that allows it)" },
  ["level.steps"] = { 13, min = 4, max = 64, step = 1, note = "Presses from dark to full (macOS uses 16)" },
  ["level.fineSteps"] = { 64, min = 16, max = 128, step = 1, note = "Same, while holding ⌥⇧ (macOS uses 64)" },
  ["hold.delay"] = { 0.3, min = 0.1, max = 1, step = 0.05, note = "Seconds a key is held before it repeats" },
  ["hold.every"] = { 0.07, min = 0.02, max = 0.3, step = 0.01, note = "Seconds between repeats while held" },
  ["ramp.seconds"] = { 0.1, min = 0, max = 0.5, step = 0.01, note = "Seconds each step glides over (0 = jump)" },
  ["match.follow"] = { false, note = "TV follows the MacBook's level (through scale and offset) instead of stepping on its own" },
  ["match.scale"] = { 1, min = 0.2, max = 3, step = 0.05, note = "TV level = MacBook level × this + offset (while following)" },
  ["match.offset"] = { 0, min = -1, max = 1, step = 0.02, note = "Added to the TV level while following (+ = TV brighter than the MacBook)" },
  ["indicator.show"] = { true, note = "Show the level bar on the TV" },
  ["indicator.hold"] = { 1, min = 0.2, max = 5, step = 0.1, note = "Seconds the bar stays after the last press" },
  ["indicator.fade"] = { 0.6, min = 0, max = 3, step = 0.05, note = "Seconds the bar takes to fade" },
  ["look.alpha"] = { 0.75, min = 0.1, max = 1, step = 0.05, note = "Opacity of the lit part of the bar" },
  ["look.trackAlpha"] = { 0.2, min = 0, max = 1, step = 0.05, note = "Opacity of the unlit part of the bar" },
  ["look.barHeight"] = { 8, min = 2, max = 20, step = 1, note = "Height of the bar in points" },
}
local previewBar
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "TV Brightness Keys",
  file = require("modules.tweaks").dir .. "/tv_brightness.json", knobs = TWEAKS,
  onChange = function() if previewBar then previewBar() end end } -- each change shows the bar
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "tv_brightness",
  name = "TV Brightness Keys",
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local KEYS = { BRIGHTNESS_UP = 1, BRIGHTNESS_DOWN = -1 }
local GLIDE_TICK = 1 / 60
local SLOT = "tv_brightness"

M.log = {}

-- ── Pure functions (no hs.*), tested by tests/tv_brightness_test.lua ─────────

-- Is a screen with this name the one to move?
function M.isTV(name, want)
  name = (name or ""):lower()
  if name:find("built-in", 1, true) or name:find("color lcd", 1, true) then return false end
  return name:find((want or ""):lower(), 1, true) ~= nil
end

-- The next grid level from `level` in direction `dir` (1 up, -1 down), clamped to 0..1.
-- Rounding first means a level off the grid (set on the slider) still moves about a
-- whole step on its first press, never a hair.
function M.nextLevel(level, dir, steps)
  local n = math.floor(level * steps + 0.5) + dir
  return math.max(0, math.min(1, n / steps))
end

-- The TV level that matches MacBook level `mac`, clamped to 0..1.
function M.matchLevel(mac, scale, offset)
  return math.max(0, math.min(1, mac * scale + offset))
end

-- How full each of the bar's n segments is (0..1) at `level`.
function M.segments(level, n)
  local out = {}
  for i = 1, n do out[i] = math.max(0, math.min(1, level * n - (i - 1))) end
  return out
end

-- What a press does given its modifiers: "skip", "fine" or "normal".
function M.pressKind(flags)
  if flags.alt and flags.shift then return "fine" end
  if flags.alt then return "skip" end
  return "normal"
end

-- ── Indicator ────────────────────────────────────────────────────────────────

local hud, fading

local function clearFade()
  if activeWatchers.tvBrightnessFade then activeWatchers.tvBrightnessFade:stop() end
  activeWatchers.tvBrightnessFade = nil
  if fading then fading:delete() end
  fading = nil
end

local function fadeHud()
  local c = hud
  hud = nil
  if not c then return end
  clearFade()
  fading = c
  c:hide(T("indicator.fade"))
  activeWatchers.tvBrightnessFade = hs.timer.doAfter(T("indicator.fade") + 0.1, clearFade)
end

local function hudElements(w, h, level)
  local dark = hs.host.interfaceStyle() == "Dark"
  local ink = dark and 1 or 0.15
  local edge = { white = dark and 0 or 1, alpha = 0.35 } -- keeps the bar readable on any picture
  local els = {
    { type = "text", text = "☀︎", frame = { x = 0, y = -2, w = 22, h = h + 2 }, textSize = 16,
      textColor = { white = ink, alpha = T("look.alpha") } },
  }
  local n = T("level.steps")
  local gap, left = 3, 26
  local segW = (w - left - gap * (n - 1)) / n
  local barH = T("look.barHeight")
  local y = (h - barH) / 2
  for i, fill in ipairs(M.segments(level, n)) do
    local x = left + (i - 1) * (segW + gap)
    els[#els + 1] = { type = "rectangle", action = "strokeAndFill", frame = { x = x, y = y, w = segW, h = barH },
      roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 }, strokeColor = edge, strokeWidth = 1,
      fillColor = { white = ink, alpha = T("look.trackAlpha") } }
    if fill > 0 then
      els[#els + 1] = { type = "rectangle", action = "fill", frame = { x = x, y = y, w = segW * fill, h = barH },
        roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 }, fillColor = { white = ink, alpha = T("look.alpha") } }
    end
  end
  return els
end

local function showLevel(tv, level)
  if not T("indicator.show") then return end
  local layout = require("modules.hud_layout")
  local slot = layout.slot(SLOT)
  if not slot then return end
  clearFade()
  local r = layout.place(tv:frame(), slot) -- on the TV even when it isn't the main screen
  if not hud then
    hud = hs.canvas.new(r)
    hud:level(hs.canvas.windowLevels.overlay)
    hud:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" }) -- also over a full-screen show
    hud:clickActivating(false)
    hud:canvasMouseEvents(false, false, false, false)
  else
    hud:frame(r)
  end
  hud:replaceElements(hudElements(r.w, r.h, level))
  hud:show()
  if activeWatchers.tvBrightnessHud then activeWatchers.tvBrightnessHud:stop() end
  activeWatchers.tvBrightnessHud = hs.timer.doAfter(T("indicator.hold"), fadeHud)
end

-- ── Moving the TV ────────────────────────────────────────────────────────────

local glide -- { tv, value, target, speed } while a step is gliding

local function stopGlide()
  if activeWatchers.tvBrightnessGlide then activeWatchers.tvBrightnessGlide:stop() end
  activeWatchers.tvBrightnessGlide = nil
  glide = nil
end

local function moveTo(tv, from, target)
  local secs = T("ramp.seconds")
  if secs <= 0 then
    stopGlide()
    tv:setBrightness(target)
    return
  end
  local value = glide and glide.value or from
  glide = { tv = tv, value = value, target = target, speed = math.abs(target - value) / secs }
  if activeWatchers.tvBrightnessGlide then return end
  activeWatchers.tvBrightnessGlide = hs.timer.doEvery(GLIDE_TICK, function()
    local g = glide
    local gap, move = g.target - g.value, g.speed * GLIDE_TICK
    g.value = math.abs(gap) <= move and g.target or g.value + (gap > 0 and move or -move)
    local ok = pcall(g.tv.setBrightness, g.tv, g.value) -- the TV may just have been unplugged
    if not ok or g.value == g.target then stopGlide() end
  end)
end

function M.findTV()
  local want = T("display.nameContains")
  for _, s in ipairs(hs.screen.allScreens()) do
    if M.isTV(s:name(), want) and type(s:getBrightness()) == "number" then return s end
  end
  return nil
end

function M.builtIn()
  for _, s in ipairs(hs.screen.allScreens()) do
    local n = (s:name() or ""):lower()
    if (n:find("built-in", 1, true) or n:find("color lcd", 1, true)) and type(s:getBrightness()) == "number" then return s end
  end
  return nil
end

-- One step. False when there's nothing more to do: no TV, or already at the end.
function M.step(dir, steps)
  local tv = glide and glide.tv or M.findTV()
  if not tv then return false end
  local now = glide and glide.target or tv:getBrightness()
  local target
  local mac = T("match.follow") and M.builtIn()
  if mac then
    -- The tap sees the key before macOS acts, so predict the MacBook's next level on its grid.
    local macNext = M.nextLevel(mac:getBrightness(), dir, steps == T("level.fineSteps") and 64 or 16)
    target = M.matchLevel(macNext, T("match.scale"), T("match.offset"))
  else
    target = M.nextLevel(now, dir, steps or T("level.steps"))
  end
  showLevel(tv, target)
  if target == now then return false end
  moveTo(tv, now, target)
  return true
end

-- Show the bar at the TV's current level without moving anything.
function M.preview()
  local tv = M.findTV()
  if tv then showLevel(tv, tv:getBrightness()) end
end
previewBar = M.preview

local function stopHold()
  if activeWatchers.tvBrightnessHold then activeWatchers.tvBrightnessHold:stop() end
  activeWatchers.tvBrightnessHold = nil
end

local function press(dir, steps)
  stopHold()
  if not M.step(dir, steps) then return end
  activeWatchers.tvBrightnessHold = hs.timer.doAfter(T("hold.delay"), function()
    activeWatchers.tvBrightnessHold = hs.timer.doEvery(T("hold.every"), function()
      if not M.step(dir, steps) then stopHold() end
    end)
  end)
end

function M.start()
  M.stop()
  activeWatchers.tvBrightnessTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
    local ok, k = pcall(e.systemKey, e)
    if not ok or type(k) ~= "table" or not k.key then return false end
    local dir = KEYS[k.key]
    if not dir then return false end
    local kind = M.pressKind(e:getFlags())
    table.insert(M.log, 1, { at = os.date("%H:%M:%S"), key = k.key, kind = kind,
      phase = k["repeat"] and "repeat" or k.down and "down" or "up" })
    M.log[41] = nil
    if k["repeat"] then return false end -- holding repeats on its own timer
    if not k.down then
      stopHold()
    elseif kind ~= "skip" then
      press(dir, kind == "fine" and T("level.fineSteps") or T("level.steps"))
    end
    return false -- macOS still gets the key
  end)
  activeWatchers.tvBrightnessTap:start()
end

function M.stop()
  stopHold()
  stopGlide()
  if activeWatchers.tvBrightnessTap then activeWatchers.tvBrightnessTap:stop() end
  activeWatchers.tvBrightnessTap = nil
  if activeWatchers.tvBrightnessHud then activeWatchers.tvBrightnessHud:stop() end
  activeWatchers.tvBrightnessHud = nil
  clearFade()
  if hud then hud:delete() end
  hud = nil
end

return M
