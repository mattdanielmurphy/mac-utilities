-- ~/.hammerspoon/modules/piano_hud.lua
-- Always-on piano capture + chord HUD (phase 1 of the "Piano scales HUD" plan).
--
--   • Listens to every hardware MIDI keyboard in the background (Ableton can use
--     the same keyboard at the same time; CoreMIDI allows many listeners).
--   • Appends every note on/off and sustain pedal event to a daily JSONL file in
--     ~/Documents/Piano Log/ (one JSON object per line).
--   • The first note pops up a small translucent HUD on the MacBook's built-in
--     display (the iPad mirrors it), else Sidecar, else the main screen. It shows
--     the chord you are holding, keeps the last chord after you let go, and fades
--     out after IDLE_HIDE seconds of silence.
--   • Click the HUD to open a card above it: the chord's intervals, the major keys
--     it belongs to (with roman numerals) and the modes it is the home chord of.
--     Escape, a click elsewhere or another click on the HUD closes it.
--
-- Virtual ports (IAC, QWERTY MIDI, anything Hammerspoon re-sends) are skipped so
-- forwarded notes are never logged twice. Toggle it from the ⚙︎ menu.

local M = {
  id = "piano_hud",
  name = "Piano Log & Chord HUD"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers
local layout = require("modules.hud_layout")

-- ── Settings (edit these, the config auto-reloads) ─────────────────────────────
local CFG = {
  LOG_DIR    = os.getenv("HOME") .. "/Documents/Piano Log",
  IDLE_HIDE  = 60,       -- seconds without a note before the HUD fades out
  FLUSH      = 2,        -- seconds between log file writes
  FADE       = 0.4,      -- show/hide fade (seconds)
  SETTLE_MS  = 80,       -- a held shape must be stable this long to become "last chord"
  WIDTH      = 300,
  HEIGHT     = 150,
  CARD_WIDTH = 380,      -- info card above the HUD (right edges line up)
  CARD_GAP   = 8,
  STUDY_KEYS = { 2, 10 },  -- D and B♭ major: listed first in the card, with a ★
  -- Device names containing any of these (case-insensitive) are not listened to.
  -- "Bluetooth" is the empty BLE driver entry; a paired keyboard shows under its own name.
  SKIP       = { "iac", "qwerty", "hammerspoon", "virtual", "network", "bluetooth" },
}
M.config = CFG

-- ── Music helpers ──────────────────────────────────────────────────────────────
local NAMES = { "C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B" }
-- Major key names: flats for the flat keys, sharps for the sharp keys.
local KEY_NAMES = { "C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B" }
local KEY_ORDER = { 0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5 }   -- circle of fifths

local function noteName(n) return NAMES[(n % 12) + 1] end

-- Chord templates as interval sets from the root. Earlier entries win ties.
local CHORDS = {
  { "",     { 0, 4, 7 } },        { "m",    { 0, 3, 7 } },
  { "7",    { 0, 4, 7, 10 } },    { "maj7", { 0, 4, 7, 11 } },
  { "m7",   { 0, 3, 7, 10 } },    { "m7♭5", { 0, 3, 6, 10 } },
  { "dim",  { 0, 3, 6 } },        { "dim7", { 0, 3, 6, 9 } },
  { "aug",  { 0, 4, 8 } },        { "sus4", { 0, 5, 7 } },
  { "sus2", { 0, 2, 7 } },        { "6",    { 0, 4, 7, 9 } },
  { "m6",   { 0, 3, 7, 9 } },     { "add9", { 0, 2, 4, 7 } },
  { "madd9",{ 0, 2, 3, 7 } },     { "9",    { 0, 2, 4, 7, 10 } },
  { "maj9", { 0, 2, 4, 7, 11 } }, { "m9",   { 0, 2, 3, 7, 10 } },
  { "7",    { 0, 4, 10 } },       { "maj7", { 0, 4, 11 } },   -- no 5th
  { "m7",   { 0, 3, 10 } },       { "5",    { 0, 7 } },
}

local INVERSION = { [3] = "1st inversion", [4] = "1st inversion",
                    [7] = "2nd inversion", [6] = "2nd inversion", [8] = "2nd inversion",
                    [10] = "3rd inversion", [11] = "3rd inversion", [9] = "3rd inversion" }

local function sameSet(a, b)
  if #a ~= #b then return false end
  local seen = {}
  for _, v in ipairs(a) do seen[v] = true end
  for _, v in ipairs(b) do if not seen[v] then return false end end
  return true
end

-- Names the chord for a list of held MIDI note numbers.
-- Returns { name = "Bm7", detail = "1st inversion", notes = "B D F♯ A",
--           pcs = {11, 2, 6, 9}, root = 11, suffix = "m7" }.
-- root/suffix are nil when no template matches.
function M.nameChord(held)
  if #held == 0 then return nil end
  held = { table.unpack(held) }
  table.sort(held)
  local bass = held[1] % 12
  local pcs, seen, order = {}, {}, {}
  for _, n in ipairs(held) do
    local pc = n % 12
    if not seen[pc] then seen[pc] = true; table.insert(pcs, pc); table.insert(order, noteName(pc)) end
  end
  local notes = table.concat(order, " ")
  local base = { notes = notes, pcs = pcs }
  if #pcs == 1 then
    base.name, base.detail, base.root, base.suffix = noteName(bass), "single note", bass, ""
    return base
  end

  local best
  for _, root in ipairs(pcs) do
    local ivs = {}
    for _, pc in ipairs(pcs) do table.insert(ivs, (pc - root) % 12) end
    for rank, ch in ipairs(CHORDS) do
      if sameSet(ivs, ch[2]) then
        -- Prefer the reading whose root is the bass note, then the earlier template.
        local score = rank + ((root == bass) and 0 or 100)
        if not best or score < best.score then
          best = { score = score, root = root, suffix = ch[1] }
        end
        break
      end
    end
  end

  if not best then
    base.name, base.detail = notes, "no common chord name"
    return base
  end
  local name = noteName(best.root) .. best.suffix
  local detail = "root position"
  if best.root ~= bass then
    name = name .. "/" .. noteName(bass)
    detail = INVERSION[(bass - best.root) % 12] or "slash chord"
  end
  base.name, base.detail, base.root, base.suffix = name, detail, best.root, best.suffix
  return base
end

-- ── Chord info (pure functions, used by the click card) ───────────────────────
local MAJOR = { 0, 2, 4, 5, 7, 9, 11 }
local TRIAD_NUM   = { "I", "ii", "iii", "IV", "V", "vi", "vii°" }
local SEVENTH_NUM = { "Imaj7", "ii7", "iii7", "IVmaj7", "V7", "vi7", "viiø7" }
local PLAIN_NUM   = { "I", "II", "III", "IV", "V", "VI", "VII" }
local MODES = { "Ionian", "Dorian", "Phrygian", "Lydian", "Mixolydian", "Aeolian", "Locrian" }
local INTERVALS = { [0] = "root", "minor 2nd", "2nd", "minor 3rd", "major 3rd", "4th",
                    "♭5", "5th", "minor 6th", "6th", "minor 7th", "major 7th" }

local function intervalName(semis, suffix)
  if semis == 2 and suffix:find("9") then return "9th" end
  if semis == 8 and suffix == "aug" then return "♯5" end
  if semis == 9 and suffix == "dim7" then return "diminished 7th" end
  return INTERVALS[semis]
end

-- Everything the card shows about a chord, from its pitch classes, root and suffix.
-- Returns { notes = "...", intervals = "...", keys = { "★ D major: vi7", ... },
--           modes = { "B Aeolian (relative minor of D major)", ... } }.
function M.chordInfo(pcs, rootPc, suffix)
  suffix = suffix or ""
  local info = { keys = {}, modes = {} }
  local names, ivs, sorted = {}, {}, {}
  for _, pc in ipairs(pcs) do table.insert(sorted, { pc = pc, iv = (pc - (rootPc or pc)) % 12 }) end
  table.sort(sorted, function(a, b) return a.iv < b.iv end)
  for _, s in ipairs(sorted) do
    table.insert(names, noteName(s.pc))
    if rootPc then table.insert(ivs, intervalName(s.iv, suffix)) end
  end
  info.notes = table.concat(names, " ")
  info.intervals = rootPc and table.concat(ivs, ", ") or nil
  if not rootPc then return info end

  local hasSeventh = false
  for _, s in ipairs(sorted) do if s.iv == 10 or s.iv == 11 then hasSeventh = true end end
  local plain = suffix:find("sus") or suffix == "5" or suffix == "6" or suffix == "m6" or suffix:find("add")

  local study, order = {}, {}
  for _, k in ipairs(CFG.STUDY_KEYS) do study[k] = true; table.insert(order, k) end
  for _, k in ipairs(KEY_ORDER) do if not study[k] then table.insert(order, k) end end

  for _, key in ipairs(order) do
    local inScale, degree = {}, nil
    for d, iv in ipairs(MAJOR) do
      inScale[(key + iv) % 12] = true
      if (key + iv) % 12 == rootPc then degree = d end
    end
    local fits = degree ~= nil
    for _, pc in ipairs(pcs) do if not inScale[pc] then fits = false end end
    if fits then
      local num
      if plain then num = PLAIN_NUM[degree] .. suffix
      elseif hasSeventh then num = SEVENTH_NUM[degree]
      else num = TRIAD_NUM[degree] end
      local keyName = KEY_NAMES[key + 1] .. " major"
      table.insert(info.keys, (study[key] and "★ " or "") .. keyName .. ": " .. num)
      local from = (degree == 1) and "the major scale itself"
        or (degree == 6) and ("relative minor of " .. keyName)
        or ("from " .. keyName)
      table.insert(info.modes, noteName(rootPc) .. " " .. MODES[degree] .. " (" .. from .. ")")
    end
  end
  return info
end

-- ── State ──────────────────────────────────────────────────────────────────────
local state = {
  devices = {},   -- name -> hs.midi object
  held = {},      -- "device:channel:note" -> note number
  buffer = {},    -- pending log lines
  lastEvent = 0,
  visible = false,
  ready = false,     -- HUD page loaded; until then render() is deferred
  lastChord = nil,   -- last settled 2+ note chord (shown after release)
  releasing = false, -- keys only going up since the last note-on
  shown = nil,       -- chord currently on the panel (what a click explains)
  shownPast = false,
  cardOpen = false,
  cardHeight = 0,
}

-- ── Log ────────────────────────────────────────────────────────────────────────
local function flush()
  if #state.buffer == 0 then return end
  hs.fs.mkdir(CFG.LOG_DIR)
  local path = CFG.LOG_DIR .. "/" .. os.date("%Y-%m-%d") .. ".jsonl"
  local f = io.open(path, "a")
  if not f then print("⚠️ piano_hud: cannot write " .. path); return end
  f:write(table.concat(state.buffer, "\n"), "\n")
  f:close()
  state.buffer = {}
end

local function logEvent(ev)
  if ev.dev == "simulated" then return end   -- test notes never reach the log
  ev.t = math.floor(hs.timer.secondsSinceEpoch() * 1000)
  table.insert(state.buffer, hs.json.encode(ev))
end

-- ── HUD ────────────────────────────────────────────────────────────────────────
local HTML = [[
<!doctype html><html><head><meta charset="utf-8"><style>
  html, body { margin: 0; height: 100%; background: transparent; overflow: hidden;
    font-family: -apple-system, "SF Pro Display", sans-serif; -webkit-user-select: none; }
  .panel { position: absolute; right: 0; bottom: 0; width: ]] .. CFG.WIDTH .. [[px;
    height: ]] .. CFG.HEIGHT .. [[px; border-radius: 14px; cursor: pointer;
    background: rgba(20, 24, 28, 0.55); color: #f4f1ea; }
  .label  { position: absolute; left: 20px; top: 14px; font-size: 11px;
    letter-spacing: 0.08em; color: rgba(244, 241, 234, 0.6); }
  .chord  { position: absolute; left: 20px; top: 32px; right: 20px; font-size: 48px;
    font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    transition: opacity 0.3s; }
  .detail { position: absolute; left: 20px; top: 94px; right: 20px; font-size: 13px;
    color: rgba(244, 241, 234, 0.75); white-space: nowrap; transition: opacity 0.3s; }
  .notes  { position: absolute; left: 20px; top: 116px; right: 20px; font-size: 12px;
    color: rgba(244, 241, 234, 0.55); white-space: nowrap; transition: opacity 0.3s; }
  .past .chord, .past .detail, .past .notes { opacity: 0.6; }
  .card { position: absolute; right: 0; width: ]] .. CFG.CARD_WIDTH .. [[px;
    bottom: ]] .. (CFG.HEIGHT + CFG.CARD_GAP) .. [[px; box-sizing: border-box;
    padding: 14px 20px 6px; border-radius: 14px; display: none;
    background: rgba(20, 24, 28, 0.55); color: #f4f1ea; font-size: 13px; line-height: 1.45; }
  .card h2 { margin: 0 0 6px; font-size: 18px; font-weight: 600; }
  .card .sec { margin-bottom: 10px; }
  .card .head { font-size: 11px; letter-spacing: 0.08em; color: rgba(244, 241, 234, 0.6);
    margin-bottom: 2px; }
  .card .row { color: rgba(244, 241, 234, 0.9); }
</style></head><body>
<div class="card" id="card"></div>
<div class="panel" id="panel">
  <div class="label" id="label">NOW HOLDING</div>
  <div class="chord" id="chord">–</div>
  <div class="detail" id="detail">&nbsp;</div>
  <div class="notes" id="notes">&nbsp;</div>
</div><script>
  function send(m) { try { webkit.messageHandlers.pianoHud.postMessage(m); } catch (e) {} }
  document.getElementById('panel').addEventListener('mousedown', function () { send({ type: 'toggle' }); });
  function update(d) {
    document.getElementById('label').textContent = d.past ? 'LAST CHORD' : 'NOW HOLDING';
    document.getElementById('panel').className = 'panel' + (d.past ? ' past' : '');
    document.getElementById('chord').textContent = d.name || '–';
    document.getElementById('detail').textContent = d.detail || ' ';
    document.getElementById('notes').textContent = d.notes || ' ';
  }
  function esc(s) { return String(s).replace(/[&<>]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }); }
  function section(head, rows) {
    if (!rows || !rows.length) return '';
    return '<div class="sec"><div class="head">' + head + '</div>' +
      rows.map(function (r) { return '<div class="row">' + esc(r) + '</div>'; }).join('') + '</div>';
  }
  function showCard(d) {
    var card = document.getElementById('card');
    var html = '<h2>' + esc(d.name) + '</h2>';
    html += section('NOTES', [d.notes + (d.intervals ? '  ·  ' + d.intervals : '')]);
    if (d.keys.length) {
      html += section('FOUND IN THESE MAJOR KEYS', d.keys);
      html += section('HOME CHORD OF THESE MODES', d.modes);
    } else {
      html += section('MAJOR KEYS', [d.none]);
    }
    card.innerHTML = html;
    card.style.display = 'block';
    send({ type: 'cardHeight', h: card.offsetHeight });
  }
  function hideCard() { document.getElementById('card').style.display = 'none'; }
</script></body></html>
]]

-- Window frame: the panel alone, or the panel plus the card above it. The panel's
-- bottom-right corner stays put either way (the page anchors it bottom-right).
-- Anchored at the "piano_hud" slot in hud_slots.json; the card grows into "piano_card".
local function hudRect()
  local w, h = CFG.WIDTH, CFG.HEIGHT
  if state.cardOpen and state.cardHeight > 0 then
    w = math.max(CFG.WIDTH, CFG.CARD_WIDTH)
    h = CFG.HEIGHT + CFG.CARD_GAP + state.cardHeight
  end
  return layout.rect("piano_hud", w, h)
end

local render, closeCard

local function onMessage(msg)
  local body = msg and msg.body or {}
  if body.type == "toggle" then
    if state.cardOpen then closeCard() else M.openCard() end
  elseif body.type == "cardHeight" and state.cardOpen then
    state.cardHeight = tonumber(body.h) or 0
    if activeWatchers.pianoHudView then activeWatchers.pianoHudView:frame(hudRect()) end
  end
end

local function ensureHud()
  if activeWatchers.pianoHudView then return activeWatchers.pianoHudView end
  state.ready = false
  local uc = hs.webview.usercontent.new("pianoHud"):setCallback(onMessage)
  local wv = hs.webview.new(hudRect(), { developerExtrasEnabled = false }, uc)
  -- The first notes arrive before the page loads; draw them once it has.
  wv:navigationCallback(function(action)
    if action == "didFinishNavigation" then state.ready = true; render() end
  end)
  wv:windowStyle({ "borderless", "nonactivating" })
    :transparent(true)
    :shadow(false)
    :level(hs.drawing.windowLevels.floating)
    :behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
    :allowTextEntry(false)
    :html(HTML)
  activeWatchers.pianoHudView = wv
  return wv
end

local function heldList()
  local list = {}
  for _, n in pairs(state.held) do table.insert(list, n) end
  return list
end

-- Draws chord c on the panel; past = it's the remembered chord, keys are up.
function render(c, past)
  if c ~= nil or past ~= nil then state.shown, state.shownPast = c, past or false end
  local wv = ensureHud()
  if not state.ready then return end
  c, past = state.shown, state.shownPast
  local d = c and { name = c.name, detail = c.detail, notes = c.notes, past = past }
    or { name = "–", detail = "", notes = "", past = false }
  wv:evaluateJavaScript("update(" .. hs.json.encode(d) .. ")")
  if state.cardOpen then M.openCard() end
end

local function remember(list)
  if #list >= 2 then state.lastChord = M.nameChord(list) end
end

-- ── Info card ──────────────────────────────────────────────────────────────────
local function stopCardWatch()
  if activeWatchers.pianoHudCardTap then activeWatchers.pianoHudCardTap:stop(); activeWatchers.pianoHudCardTap = nil end
end

function closeCard()
  stopCardWatch()
  if not state.cardOpen then return end
  state.cardOpen, state.cardHeight = false, 0
  local wv = activeWatchers.pianoHudView
  if wv then
    wv:evaluateJavaScript("hideCard()")
    wv:frame(hudRect())
  end
end
M.closeCard = function() closeCard() end

-- Opens (or refreshes) the card for the chord on the panel.
function M.openCard()
  local c = state.shown
  local wv = activeWatchers.pianoHudView
  if not c or not wv or not state.ready then return end
  local info = M.chordInfo(c.pcs, c.root, c.suffix)
  local d = { name = c.name, notes = info.notes, intervals = info.intervals,
              keys = info.keys, modes = info.modes,
              none = c.root and "Not in any major key (it comes from harmonic minor or a symmetric scale)."
                or "No common chord name, so no key list." }
  state.cardOpen = true
  state.lastEvent = hs.timer.secondsSinceEpoch()   -- reading counts as activity
  wv:evaluateJavaScript("showCard(" .. hs.json.encode(d) .. ")")

  if not activeWatchers.pianoHudCardTap then
    local types = hs.eventtap.event.types
    activeWatchers.pianoHudCardTap = hs.eventtap.new({ types.leftMouseDown, types.keyDown }, function(e)
      if e:getType() == types.keyDown then
        if e:getKeyCode() == hs.keycodes.map.escape then hs.timer.doAfter(0, closeCard) end
        return false
      end
      local p, f = hs.mouse.absolutePosition(), hudRect()
      if p.x < f.x or p.x > f.x + f.w or p.y < f.y or p.y > f.y + f.h then
        hs.timer.doAfter(0, closeCard)
      end
      return false
    end):start()
  end
end

local function showHud()
  if state.visible then return end
  local wv = ensureHud()
  wv:frame(hudRect())
  wv:show(CFG.FADE)
  state.visible = true
end

local function hideHud()
  if not state.visible then return end
  closeCard()
  if activeWatchers.pianoHudView then activeWatchers.pianoHudView:hide(CFG.FADE) end
  state.visible = false
  state.lastChord, state.shown = nil, nil
end

-- ── MIDI ───────────────────────────────────────────────────────────────────────
local function skipDevice(name)
  local n = (name or ""):lower()
  for _, s in ipairs(CFG.SKIP) do if n:find(s, 1, true) then return true end end
  return false
end

local function onMidi(_, devName, cmd, _, meta)
  if cmd ~= "noteOn" and cmd ~= "noteOff" and cmd ~= "controlChange" then return end
  local ch = meta.channel or 0
  if cmd == "controlChange" then
    if meta.controllerNumber ~= 64 then return end
    logEvent({ type = "sustain", value = meta.controllerValue, ch = ch, dev = devName })
    return
  end
  local note, vel = meta.note, meta.velocity or 0
  local key = devName .. ":" .. ch .. ":" .. note
  state.lastEvent = hs.timer.secondsSinceEpoch()
  showHud()
  if cmd == "noteOn" and vel > 0 then
    state.held[key] = note
    logEvent({ type = "on", note = note, vel = vel, ch = ch, dev = devName })
    state.releasing = false
    -- Rolled chords: only a shape that holds still for SETTLE_MS is remembered.
    if activeWatchers.pianoHudSettle then activeWatchers.pianoHudSettle:stop() end
    activeWatchers.pianoHudSettle = hs.timer.doAfter(CFG.SETTLE_MS / 1000, function()
      activeWatchers.pianoHudSettle = nil
      if not state.releasing then remember(heldList()) end
    end)
    render(M.nameChord(heldList()), false)
  else
    logEvent({ type = "off", note = note, ch = ch, dev = devName })
    if state.held[key] == nil then return end
    -- Keys going up never change the remembered chord (legato overlaps and
    -- release fragments would otherwise replace it).
    state.releasing = true
    if activeWatchers.pianoHudSettle then activeWatchers.pianoHudSettle:stop(); activeWatchers.pianoHudSettle = nil end
    state.held[key] = nil
    -- Release fragments never reach the screen; switch once every key is up.
    if next(state.held) == nil then
      if state.lastChord then render(state.lastChord, true) else render(false, false) end
    end
  end
end

local function connectDevices()
  local wanted = {}
  for _, name in ipairs(hs.midi.devices() or {}) do
    if not skipDevice(name) then wanted[name] = true end
  end
  for name, dev in pairs(state.devices) do
    if not wanted[name] then dev:callback(nil); state.devices[name] = nil end
  end
  for name in pairs(wanted) do
    if not state.devices[name] then
      local dev = hs.midi.new(name)
      if dev then
        dev:callback(onMidi)
        state.devices[name] = dev
        print("🎹 piano_hud: listening to " .. name)
      end
    end
  end
  activeWatchers.pianoHudDevices = state.devices
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────────
function M.start()
  M.stop()
  connectDevices()
  hs.midi.deviceCallback(function() connectDevices() end)

  activeWatchers.pianoHudTimer = hs.timer.doEvery(CFG.FLUSH, function()
    flush()
    if state.visible and hs.timer.secondsSinceEpoch() - state.lastEvent > CFG.IDLE_HIDE then
      state.held = {}
      hideHud()
    end
  end)

  activeWatchers.pianoHudScreens = hs.screen.watcher.new(function()
    if activeWatchers.pianoHudView then activeWatchers.pianoHudView:frame(hudRect()) end
  end):start()
end

function M.stop()
  flush()
  stopCardWatch()
  hs.midi.deviceCallback(nil)
  for _, dev in pairs(state.devices) do dev:callback(nil) end
  state.devices, state.held = {}, {}
  if activeWatchers.pianoHudTimer then activeWatchers.pianoHudTimer:stop(); activeWatchers.pianoHudTimer = nil end
  if activeWatchers.pianoHudScreens then activeWatchers.pianoHudScreens:stop(); activeWatchers.pianoHudScreens = nil end
  if activeWatchers.pianoHudView then activeWatchers.pianoHudView:delete(); activeWatchers.pianoHudView = nil end
  activeWatchers.pianoHudDevices = nil
  state.visible, state.ready, state.cardOpen, state.cardHeight = false, false, false, 0
  if activeWatchers.pianoHudSettle then activeWatchers.pianoHudSettle:stop(); activeWatchers.pianoHudSettle = nil end
  state.lastChord, state.shown, state.shownPast, state.releasing = nil, nil, false, false
end

-- Lets a test (hs -c) feed notes without a keyboard: M.simulate("noteOn", 62, 90)
function M.simulate(cmd, note, vel)
  onMidi(nil, "simulated", cmd, nil, { note = note, velocity = vel or 90, channel = 1 })
end

-- Test hook: what the HUD is showing right now.
function M.status()
  local wv = activeWatchers.pianoHudView
  local f = wv and wv:frame()
  return { visible = wv and wv:isVisible() or false, cardOpen = state.cardOpen,
           shown = state.shown and state.shown.name, past = state.shownPast,
           frame = f and string.format("%d,%d %dx%d", f.x, f.y, f.w, f.h) }
end

return M
