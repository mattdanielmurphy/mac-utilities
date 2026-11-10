-- ~/.hammerspoon/modules/logic_keys.lua
-- Hold a letter to type a logic symbol in any app, like Apple's accent popup.
-- (That popup can't be extended: its tables live on the sealed system volume.)
--
--   Hold E → a small picker appears mid-screen → press 1 → the e becomes ∃.
--   Hold A offers 1 ∀ and 2 ∧. Any other key, a click elsewhere or Esc closes the
--   picker and the typed letter stays. The picker's bottom line lists every key.
--
-- Normal typing: the first press always passes straight through, untouched. Only the
-- auto-repeats of a mapped letter are held back. Keep holding past repeat.after and
-- they flow again: letters repeat, or Apple's own accent popup shows in native apps.
-- The picker only opens in a text input; anywhere else, or if focus is unclear, holds
-- behave as if this module weren't here.
-- Only real key presses count (PID 0), so scripted typing never opens the picker.
--
-- The state machine (M.decide) needs no hs.*: lua tests/logic_keys_test.lua

local TWEAKS = {
  ["hold.delay"] = { 0.35, min = 0.25, max = 1, step = 0.05, note = "Seconds a letter is held before the picker opens" },
  ["repeat.after"] = { 1.5, min = 0.8, max = 4, step = 0.1, note = "Seconds of holding before normal key repeat takes over" },
  ["picker.seconds"] = { 8, min = 2, max = 30, step = 1, note = "Seconds the picker waits before closing itself" },
  ["picker.scale"] = { 1.6, min = 1, max = 2.5, step = 0.1, note = "Overall picker size" },
  ["picker.symbolSize"] = { 26, min = 16, max = 40, step = 1, note = "Symbol size in the picker" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Logic keys",
  file = require("modules.tweaks").dir .. "/logic_keys.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "logic_keys",
  name = "Logic Keys (hold a letter for ∀ ∃ ¬ …)",
  defaultEnabled = true
}

-- Same symbols as the Logic Symbol Editor (modules/logic_editor.lua), except its ⌥ digits.
-- Letters are mnemonics: All/And, Exists, Not, Or, If-then, Both ways, Turnstile/Top,
-- So, False, Xor.
M.KEYS = {
  a = { "∀", "∧" }, e = { "∃" }, n = { "¬" }, o = { "∨" }, i = { "→" },
  b = { "↔" }, ["="] = { "≠", "≡" }, t = { "⊢", "⊨", "⊤" }, s = { "∴" }, f = { "⊥" }, x = { "⊕" },
}
M.MEANINGS = {
  a = "for all / and", e = "there exists", n = "not", o = "or", i = "implies", b = "if and only if",
  ["="] = "not equal / same", t = "proves / models / true", s = "therefore", f = "false", x = "exclusive or",
}
M.CHEAT_ORDER = { "a", "e", "n", "o", "i", "b", "=", "t", "s", "f", "x" }

-- Holding keys is the point in these: games, music typing, Logic.
local SKIP_APPS = {
  ["com.apple.logic10"] = true,
  ["com.apple.garageband10"] = true,
  ["com.mojang.minecraftlauncher"] = true,
  ["net.java.openjdk.cmd"] = true,
  ["com.valvesoftware.steam"] = true,
}

-- Terminals show their typing area as a read-only text view, but it does take typing.
local TERMINALS = {
  ["com.apple.Terminal"] = true,
  ["com.googlecode.iterm2"] = true,
  ["net.kovidgoyal.kitty"] = true,
  ["dev.warp.Warp-Stable"] = true,
  ["com.github.wez.wezterm"] = true,
  ["com.mitchellh.ghostty"] = true,
  ["io.alacritty"] = true,
}

-- Is this focused element somewhere typing goes? Anything unknown is a no.
-- info = { role, subrole, editableAncestor, valueSettable, terminal } (pure)
function M.isTextInput(info)
  if not info or not info.role then return false end
  if info.subrole == "AXSecureTextField" then return false end
  if info.role == "AXTextField" or info.role == "AXComboBox" then return true end
  if info.role == "AXTextArea" then return info.valueSettable or info.editableAncestor or info.terminal or false end
  return info.editableAncestor == true -- web contenteditable boxes
end

-- ── State machine (pure) ──────────────────────────────────────────────────────
-- ev = { kind = "down"|"repeat"|"up", key = "e", mods = bool, now = seconds }
-- s = { held, since, shown, passing, spent, open, picked }. Returns "pass" or
-- "swallow", plus an action: "open", "close" or "choose" (with its 1-based index).

function M.newState() return {} end

function M.decide(s, ev, cfg)
  if ev.kind == "up" then
    if ev.key == s.held then s.held = nil end
    return "pass"
  end

  if ev.kind == "repeat" then
    if ev.key ~= s.held then return "pass" end
    if s.spent then return "swallow" end
    if s.passing then return "pass" end
    if cfg.skip then s.passing = true; return "pass" end
    local elapsed = ev.now - s.since
    if elapsed >= cfg.repeatAfter then
      s.passing = true
      if s.open then s.open = false; return "pass", "close" end
      return "pass"
    end
    if not s.shown and elapsed >= cfg.holdDelay then
      s.shown, s.open = true, true
      return "swallow", "open"
    end
    return "swallow"
  end

  -- A fresh press.
  local action
  if s.open then
    s.open = false
    local n = (not ev.mods) and tonumber(ev.key) or nil
    if n and M.KEYS[s.picked][n] then s.spent = true; return "swallow", "choose", n end
    if ev.key == "escape" and not ev.mods then s.spent = true; return "swallow", "close" end
    action = "close"
  end
  s.checked = nil
  if M.KEYS[ev.key] and not ev.mods then
    s.held, s.since, s.shown, s.passing, s.spent, s.picked = ev.key, ev.now, false, false, nil, ev.key
  else
    s.held, s.spent = nil, nil -- typing moved on, so this was no hold
  end
  return "pass", action
end

if not (hs and type(hs.reload) == "function") then return M end

-- ── Picker ────────────────────────────────────────────────────────────────────

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local palette = require("modules.slub_palette")
local types = hs.eventtap.event.types
local props = hs.eventtap.event.properties

local state = M.newState()
local canvas, closeTimer, mouseTap
local hits = {} -- clickable picker cells: { frame, symbol }, in unscaled picker points
local W, H = 520, 246

local function closePicker()
  if closeTimer then closeTimer:stop(); closeTimer = nil end
  if mouseTap then mouseTap:stop(); mouseTap = nil end
  if canvas then canvas:delete(); canvas = nil end
  state.open = false
end

local function insert(symbol)
  local function go(release)
    hs.eventtap.keyStroke({}, "delete", 0)
    hs.eventtap.keyStrokes(symbol)
    release()
  end
  if _G.claudeControl and _G.claudeControl.withInput then
    _G.claudeControl.withInput("logic_keys", go)
  else
    go(function() end)
  end
end

local function pickerFrame()
  local screen = hs.screen.mainScreen():frame()
  local w, h = W * T("picker.scale"), H * T("picker.scale")
  return { x = screen.x + (screen.w - w) / 2, y = screen.y + (screen.h - h) / 2, w = w, h = h }
end

-- The key list: two Key | Symbol tables side by side, split so the left is never shorter.
local function appendTables(fg, muted, line)
  local rowH, top, tableW = 22, 68, (W - 36) / 2
  local perTable = math.ceil(#M.CHEAT_ORDER / 2)
  for t = 0, 1 do
    local x = 12 + t * (tableW + 12)
    canvas:appendElements(
      { type = "text", text = "Key", textSize = 11, textColor = muted, frame = { x = x + 8, y = top, w = 28, h = 16 } },
      { type = "text", text = "Symbol", textSize = 11, textColor = muted, frame = { x = x + 38, y = top, w = 80, h = 16 } },
      { type = "text", text = "Means", textSize = 11, textColor = muted, frame = { x = x + 128, y = top, w = 80, h = 16 } })
    for row = 1, perTable do
      local key = M.CHEAT_ORDER[t * perTable + row]
      local y = top + 18 + (row - 1) * rowH
      canvas:appendElements({ type = "rectangle", action = "fill", fillColor = line,
        frame = { x = x, y = y, w = tableW, h = 1 } })
      if key then
        canvas:appendElements(
          { type = "text", text = hs.styledtext.new(key:upper(), { font = { name = "HelveticaNeue-Bold", size = 14 }, color = fg }),
            frame = { x = x + 8, y = y + 2, w = 28, h = 20 } },
          { type = "text", text = M.MEANINGS[key], textSize = 11, textColor = muted,
            frame = { x = x + 128, y = y + 4, w = tableW - 128, h = 16 } })
        for i, symbol in ipairs(M.KEYS[key]) do
          local cell = { x = x + 36 + (i - 1) * 30, y = y + 1, w = 28, h = rowH - 1 }
          canvas:appendElements(
            { type = "text", text = symbol, textSize = 16, textColor = fg, textAlignment = "center", frame = cell })
          hits[#hits + 1] = { frame = cell, symbol = symbol }
        end
      end
    end
  end
end

local function showPicker(key)
  closePicker()
  state.open = true
  local choices = M.KEYS[key]
  hits = {}
  local sys = hs.drawing.color.colorsFor("System")
  local fg, muted = sys.labelColor, sys.secondaryLabelColor
  local seeds = palette.seeds()
  local accent = seeds and { hex = seeds.accent } or sys.controlAccentColor

  canvas = hs.canvas.new(pickerFrame())
  canvas:transformation(hs.canvas.matrix.scale(T("picker.scale")))
  canvas:level(hs.canvas.windowLevels.popUpMenu)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas[1] = { type = "rectangle", action = "strokeAndFill", fillColor = sys.windowBackgroundColor,
    strokeColor = sys.separatorColor, strokeWidth = 1, roundedRectRadii = { xRadius = 10, yRadius = 10 } }
  for i, symbol in ipairs(choices) do
    local x = 12 + (i - 1) * 84
    hits[#hits + 1] = { frame = { x = x, y = 12, w = 76, h = 48 }, symbol = symbol }
    canvas:appendElements(
      { type = "rectangle", action = "stroke", strokeColor = accent, strokeWidth = 1.5,
        frame = { x = x, y = 12, w = 76, h = 48 },
        roundedRectRadii = { xRadius = 8, yRadius = 8 } },
      { type = "text", text = tostring(i), textSize = 13, textColor = muted,
        frame = { x = x + 10, y = 26, w = 18, h = 20 } },
      { type = "text", text = symbol, textSize = T("picker.symbolSize"), textColor = fg,
        frame = { x = x + 30, y = 15, w = 44, h = 42 } })
  end
  canvas:appendElements(
    { type = "text", text = "Press a number. Esc cancels. Keep holding to repeat.", textSize = 11,
      textColor = muted, textAlignment = "center", frame = { x = 8, y = H - 24, w = W - 16, h = 18 } })
  appendTables(fg, muted, sys.separatorColor)
  canvas:show()

  closeTimer = hs.timer.doAfter(T("picker.seconds"), closePicker)
  mouseTap = hs.eventtap.new({ types.leftMouseDown, types.rightMouseDown }, function(e)
    if not canvas then return false end
    local p, f = e:location(), canvas:frame()
    if not (p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h) then
      hs.timer.doAfter(0, closePicker) -- the caret may move, so the offer is off
      return false
    end
    -- Clicks are read here, not by the canvas: canvas hit-testing failed on the live picker.
    local scale = T("picker.scale")
    local px, py = (p.x - f.x) / scale, (p.y - f.y) / scale
    for _, hit in ipairs(hits) do
      local c = hit.frame
      if px >= c.x and px <= c.x + c.w and py >= c.y and py <= c.y + c.h then
        hs.timer.doAfter(0, function()
          closePicker()
          state.spent = state.held ~= nil
          insert(hit.symbol)
        end)
        break
      end
    end
    return true -- never click through to the app underneath
  end):start()
end

local function focusInfo(app)
  local el = hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  if not el then return nil end
  return {
    role = el:attributeValue("AXRole"),
    subrole = el:attributeValue("AXSubrole"),
    editableAncestor = el:attributeValue("AXEditableAncestor") ~= nil,
    valueSettable = el:isAttributeSettable("AXValue") == true,
    terminal = TERMINALS[app:bundleID()] == true,
  }
end

-- Electron apps hide their insides until asked, so a miss turns that on for the next hold.
function M.textInputFocused(app)
  local ok, info = pcall(focusInfo, app)
  local yes = ok and M.isTextInput(info)
  if not yes then
    pcall(function() hs.axuielement.applicationElement(app):setAttributeValue("AXManualAccessibility", true) end)
  end
  return yes
end

local function appIsSkipped()
  if hs.eventtap.isSecureInputEnabled() then return true end
  local midi = activeWatchers.midiKeyTap -- QWERTY MIDI armed: keys are notes
  if midi and midi:isEnabled() then return true end
  local app = hs.application.frontmostApplication()
  if not app or SKIP_APPS[app:bundleID()] then return true end
  return not M.textInputFocused(app)
end

local function onEvent(e)
  if e:getProperty(props.eventSourceUnixProcessID) ~= 0 and not M.testMode then return false end
  local isDown = e:getType() == types.keyDown
  local key = hs.keycodes.map[e:getKeyCode()]
  local flags = e:getFlags()
  local kind = not isDown and "up" or (e:getProperty(props.keyboardEventAutorepeat) ~= 0 and "repeat" or "down")
  local now = hs.timer.secondsSinceEpoch()
  local cfg = { holdDelay = T("hold.delay"), repeatAfter = T("repeat.after") }
  if kind == "repeat" and key == state.held and not state.checked and not state.spent then
    state.checked = true -- once per hold, on the first repeat, so repeats elsewhere never wait
    cfg.skip = appIsSkipped()
  end
  local verdict, action, n = M.decide(state, {
    kind = kind, key = key, now = now, mods = flags.cmd or flags.alt or flags.ctrl or flags.fn or false,
  }, cfg)
  local picked = state.picked
  if action == "open" then
    hs.timer.doAfter(0, function() if state.open then showPicker(picked) end end)
  elseif action == "close" then
    hs.timer.doAfter(0, closePicker)
  elseif action == "choose" then
    local symbol = M.KEYS[picked][n]
    hs.timer.doAfter(0, function() closePicker(); insert(symbol) end)
  end
  return verdict == "swallow"
end

function M.start()
  M.stop()
  activeWatchers.logicKeysTap = hs.eventtap.new({ types.keyDown, types.keyUp }, onEvent):start()
end

function M.stop()
  if activeWatchers.logicKeysTap then activeWatchers.logicKeysTap:stop(); activeWatchers.logicKeysTap = nil end
  closePicker()
  state = M.newState()
end

M.showPicker = showPicker -- lets a test show it without holding a key

return M
