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

-- Feel knobs (⌃⌥⌘T Tweaks panel); found by bin/tweaks scan, kept by prune.
local TWEAKS = {
  ["timing.idleHide"] = { 120, min = 5, max = 600, step = 5, note = "Seconds without a note before the HUD fades out" },
  ["timing.dismissQuiet"] = { 10, min = 0, max = 120, step = 1, note = "After you close the HUD (× or Esc), seconds of silence before a note brings it back" },
  ["timing.peekSec"] = { 3, min = 0.5, max = 10, step = 0.5, note = "Seconds the keyboard strip pops back after a muted note in a key you know" },
  ["muted.hold"] = { 0.6, min = 0.1, max = 3, step = 0.1, note = "Seconds a muted note's flash stays before fading" },
  ["learn.learningMinutes"] = { 15, min = 1, max = 300, step = 1, note = "Minutes in a key before its full keyboard shrinks to one octave" },
  ["learn.familiarMinutes"] = { 45, min = 1, max = 600, step = 5, note = "Minutes in a key (with few wrong notes) before the keyboard hides" },
  ["learn.knownMinutes"] = { 120, min = 1, max = 900, step = 5, note = "Minutes in a key (with very few wrong notes) before only the key name shows" },
  ["song.holdSec"] = { 8, min = 2, max = 120, step = 1, note = "After a song stops, seconds without a piano note before the panel leaves the song's key" },
  ["learn.knownKeys"] = { "C,G,F,E", note = "Major keys you already know: they never show the keyboard (comma-separated, e.g. C,G,F,E,Bb)" },
  ["fade.duration"] = { 0.4, min = 0.05, max = 2, step = 0.05, note = "Seconds for the HUD show/hide fade" },
  ["timing.settleMs"] = { 80, min = 10, max = 400, step = 10, note = "Milliseconds a held shape must be stable to count as last chord" },
  ["look.width"] = { 300, min = 200, max = 600, step = 10, note = "HUD width in pixels" },
  ["look.height"] = { 150, min = 100, max = 400, step = 10, note = "HUD height in pixels" },
  ["card.width"] = { 380, min = 260, max = 600, step = 10, note = "Info card width in pixels" },
  ["card.gap"] = { 8, min = 0, max = 40, step = 1, note = "Pixels between the info card and the HUD" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Piano Log & Chord HUD",
  file = require("modules.tweaks").dir .. "/piano_hud.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

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
  IDLE_HIDE = T("timing.idleHide"),       -- seconds without a note before the HUD fades out
  DISMISS_QUIET = T("timing.dismissQuiet"), -- silence needed before a closed HUD comes back
  PEEK = T("timing.peekSec"),             -- keyboard pops back this long after a muted note
  MUTED_HOLD = T("muted.hold"),
  FLUSH      = 2,        -- seconds between log file writes
  FADE = T("fade.duration"),      -- show/hide fade (seconds)
  SETTLE_MS = T("timing.settleMs"),       -- a held shape must be stable this long to become "last chord"
  WIDTH = T("look.width"),
  HEIGHT = T("look.height"),
  CARD_WIDTH = T("card.width"),      -- info card above the HUD (right edges line up)
  CARD_GAP = T("card.gap"),
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
<!doctype html><html><head><meta charset="utf-8">@GUARD@<style>
  html, body { margin: 0; height: 100%; background: transparent; overflow: hidden;
    font-family: -apple-system, "SF Pro Display", sans-serif; -webkit-user-select: none; }
  .panel { position: absolute; right: 0; bottom: 0; width: ]] .. CFG.WIDTH .. [[px;
    height: ]] .. CFG.HEIGHT .. [[px; border-radius: 14px; cursor: pointer;
    background: rgba(20, 24, 28, 0.55); color: #f4f1ea; }
  .label  { position: absolute; left: 20px; top: 14px; font-size: 11px;
    letter-spacing: 0.08em; color: rgba(244, 241, 234, 0.6); }
  .chord  { position: absolute; left: 20px; top: 32px; right: 20px; font-size: 48px;
    font-weight: 600; white-space: nowrap; overflow: hidden;
    transition: opacity 0.3s; }
  .detail { position: absolute; left: 20px; top: 94px; right: 20px; font-size: 13px;
    color: rgba(244, 241, 234, 0.75); white-space: nowrap; transition: opacity 0.3s; }
  .notes  { position: absolute; left: 20px; top: 116px; right: 20px; font-size: 12px;
    color: rgba(244, 241, 234, 0.55); white-space: nowrap; transition: opacity 0.3s; }
  .past .chord, .past .detail, .past .notes { opacity: 0.6; }
  .save   { position: absolute; right: 12px; top: 9px; padding: 3px 9px; border-radius: 8px;
    font-size: 11px; letter-spacing: 0.04em; color: rgba(244, 241, 234, 0.8);
    background: rgba(244, 241, 234, 0.12); transition: opacity 0.3s; }
  .save:hover { background: rgba(244, 241, 234, 0.22); }
  .save.busy { opacity: 0.5; }
  .card { position: absolute; right: 0; width: ]] .. CFG.CARD_WIDTH .. [[px;
    bottom: ]] .. (CFG.HEIGHT + CFG.CARD_GAP) .. [[px; box-sizing: border-box;
    padding: 14px 20px 6px; border-radius: 14px; display: none;
    background: rgba(20, 24, 28, 0.55); color: #f4f1ea; font-size: 13px; line-height: 1.45; }
  .card h2 { margin: 0 0 6px; font-size: 18px; font-weight: 600; }
  .card .sec { margin-bottom: 10px; }
  .card .head { font-size: 11px; letter-spacing: 0.08em; color: rgba(244, 241, 234, 0.6);
    margin-bottom: 2px; }
  .card .row { color: rgba(244, 241, 234, 0.9); }

  /* ── Key-of-the-week panel (shown while the piano key-lock is on) ──
     Built on Slub Guard (modules/guard_kit.lua, look A): rows have fixed heights, live text stays on one
     line, controls never shrink, colours come by role from the palette seeds. Only the keyboard strip and
     the letters row below are drawn here; they use the guard roles too. */
  .kp { position: absolute; right: 0; bottom: 0; --g-w: ]] .. CFG.WIDTH .. [[px; display: none; cursor: default;
    --white: var(--g-key-white); --offwhite: var(--g-sunk); --black: var(--g-key-black); --offblack: var(--g-line-strong);
    --ink: var(--g-text); --soft: var(--g-soft); --line: var(--g-line); --accent: var(--g-accent); --mutedInk: var(--g-danger); }
  /* Keys stay light in both schemes, so letters and the tonic dot on white keys use dark key ink; in dark,
     out-of-key white keys stay a mid tone so they never read as black keys. */
  .kp { --keyInk: var(--g-text); --keySoft: var(--g-soft); }
  @media (prefers-color-scheme: dark) { .kp { --offwhite: var(--g-faint); --offblack: var(--g-line);
    --keyInk: var(--g-key-black); --keySoft: color-mix(in oklab, var(--g-key-black) 72%, var(--g-key-white)); } }
  #kpHold, #kpMuted { font-family: var(--g-font-round); }
  .kp-name { flex: 0 1 auto; }
  .kp-weekly { display: none; }
  .kp-muted { transition: opacity 0.5s; }
  .kp-hint { text-align: right; }
  .kp-song { display: none; }
  .kp-strip { position: relative; margin: 2px 0 4px; display: none; }
  .k { position: absolute; top: 0; box-sizing: border-box; border-radius: 0 0 3px 3px; }
  .k.w { background: var(--offwhite); border: 1px solid var(--line); }
  .k.w.in { background: var(--white); }
  .k.b { background: var(--offblack); z-index: 2; }
  .k.b.in { background: var(--black); }
  .k.held { background: var(--accent) !important; box-shadow: 0 0 8px var(--accent); }
  .k .lt { position: absolute; left: 0; right: 0; bottom: 2px; text-align: center; font-size: 9px; color: var(--keySoft); }
  .k.tonic .lt { color: var(--keyInk); font-weight: 600; }
  .k.tonic::after { content: ""; position: absolute; left: 50%; bottom: 14px; width: 6px; height: 6px;
    margin-left: -3px; border-radius: 3px; background: var(--keyInk); }
  .k.b.tonic::after { background: var(--white); bottom: 4px; }
  /* held wins over tonic / black-key colours (comes after them on purpose) */
  .k.held .lt, .k.held.tonic .lt { color: var(--g-accent-ink); font-weight: 600; }
  .k.held.tonic::after, .k.b.held.tonic::after { background: var(--g-accent-ink); }
  .k.muted { outline: 1.5px dashed var(--mutedInk); outline-offset: -2px; animation: mute 1s ease-out; }
  @keyframes mute { 0% { opacity: 0.4 } 8% { opacity: 1 } 100% { opacity: 1 } }
  .kp-letters { display: none; gap: 4px; white-space: nowrap; overflow: hidden; font: 500 15px/20px var(--g-font-round); height: 20px; }
  .kp-letters span { color: var(--soft); padding: 0 3px; border-radius: 3px; }
  .kp-letters .tonic { color: var(--ink); font-weight: 600; text-decoration: underline; text-decoration-color: var(--accent);
    text-decoration-thickness: 3px; text-underline-offset: 3px; }
  .kp-letters .held { color: var(--g-accent-ink); background: var(--g-accent); }
  .kp-letters .tonic.held { text-decoration-color: var(--g-accent-ink); }
</style></head><body class="g">
<div class="card" id="card"></div>
<div class="kp g-panel" id="kp">
  <div class="g-row h18 kp-top"><span class="g-label g-keep" id="kpLabel">Key of the week</span>
    <span class="g-grow"></span>
    <span class="g-chip kp-weekly" id="kpWeekly" title="Go back to this week's key">back to weekly</span>
    <span class="g-kbd">Esc</span><button class="g-icon" id="kpX" title="Hide (Esc). Hides on its own after 2 idle minutes and comes back when you play again">×</button></div>
  <div class="g-row h18 kp-song" id="kpSongRow"><span class="g-live g-strong" id="kpSong"></span></div>
  <div class="g-row h28"><button class="g-arrow" id="kpPrev" title="Previous key (one flat more)">‹</button>
    <span class="g-title g-live kp-name" id="kpName">C major</span><span class="g-sub g-give" id="kpRel"></span>
    <button class="g-arrow" id="kpNext" title="Next key (one sharp more)">›</button></div>
  <div class="kp-strip" id="kpStrip"></div>
  <div class="kp-letters" id="kpLetters"></div>
  <div class="g-row h18 g-hint"><span class="g-label g-keep" id="kpHoldLbl"></span><span class="g-strong g-keep" id="kpHold"></span>
    <span class="g-bad g-keep kp-muted" id="kpMuted"></span><span class="g-give kp-hint" id="kpHint"></span></div>
</div>
<div class="panel" id="panel">
  <div class="label" id="label">NOW HOLDING</div>
  <div class="save" id="save" title="Save this session as a MIDI file">Save MIDI</div>
  <div class="chord g-live" id="chord">–</div>
  <div class="detail" id="detail">&nbsp;</div>
  <div class="notes" id="notes">&nbsp;</div>
</div><script>
  function send(m) { try { webkit.messageHandlers.pianoHud.postMessage(m); } catch (e) {} }
  document.getElementById('panel').addEventListener('mousedown', function () { send({ type: 'toggle' }); });
  document.getElementById('save').addEventListener('mousedown', function (e) {
    e.stopPropagation();   // the rest of the panel opens the chord card
    if (this.classList.contains('busy')) return;
    this.classList.add('busy');
    send({ type: 'saveMidi' });
  });
  // Shows the save result on the button for a moment, then puts the label back.
  function saved(d) {
    var text = d.text;
    var b = document.getElementById('save');
    b.classList.remove('busy');
    b.textContent = text;
    setTimeout(function () { b.textContent = 'Save MIDI'; }, 2500);
  }
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

  // ── Key-of-the-week panel ──
  function pretty(n) { return String(n).replace(/#/g, '♯').replace(/([A-G])b/g, '$1♭'); }
  // Drag the panel anywhere that isn't a control (shared modules/hud_move.lua); double-click the
  // top row to send it back to its slot.
  document.getElementById('kp').addEventListener('mousedown', function (e) {
    if (e.button === 0 && !e.target.closest('.g-icon, .g-arrow, .kp-weekly')) send({ type: 'dragStart' });
  });
  document.querySelector('.kp-top').addEventListener('dblclick', function (e) {
    if (!e.target.closest('.g-icon, .kp-weekly')) send({ type: 'dragReset' });
  });
  ['kpX', 'kpPrev', 'kpNext', 'kpWeekly'].forEach(function (id) {
    document.getElementById(id).addEventListener('mousedown', function (e) {
      e.stopPropagation(); send({ type: id });
    });
  });
  var WHITE = [0, 2, 4, 5, 7, 9, 11], BLACK = { 1: 0, 3: 1, 6: 3, 8: 4, 10: 5 };
  function strip(d, octs, ww, h, letters) {
    var inKey = {}, held = {}, html = '';
    d.pcs.forEach(function (pc, i) { inKey[pc] = d.names[i]; });
    d.held.forEach(function (pc) { held[pc] = true; });
    var bw = Math.round(ww * 0.62), bh = Math.round(h * 0.6);
    function cls(pc, kind) {
      return 'k ' + kind + (inKey[pc] !== undefined ? ' in' : '') + (pc === d.tonic ? ' tonic' : '') +
        (held[pc] ? ' held' : '') + (pc === d.muted ? ' muted' : '');
    }
    for (var o = 0; o < octs; o++) {
      WHITE.forEach(function (pc, i) {
        var lt = letters && inKey[pc] !== undefined ? '<span class="lt">' + pretty(inKey[pc]) + '</span>' : '';
        html += '<div class="' + cls(pc, 'w') + '" style="left:' + ((o * 7 + i) * ww) + 'px;width:' + (ww + 1) +
          'px;height:' + h + 'px">' + lt + '</div>';
      });
      Object.keys(BLACK).forEach(function (k) {
        var pc = +k, left = (o * 7 + BLACK[k] + 1) * ww - bw / 2;
        html += '<div class="' + cls(pc, 'b') + '" style="left:' + left + 'px;width:' + bw + 'px;height:' + bh + 'px"></div>';
      });
    }
    var el = document.getElementById('kpStrip');
    el.innerHTML = html; el.style.height = h + 'px'; el.style.width = (octs * 7 * ww + 1) + 'px';
    el.style.display = 'block';
  }
  var mutedTimer = null;
  function keyUpdate(d) {
    document.getElementById('panel').style.display = 'none';
    var kp = document.getElementById('kp'); kp.style.display = 'flex';
    document.getElementById('kpLabel').textContent = d.label;
    document.getElementById('kpSong').textContent = d.song ? '♪ ' + d.song : '';
    document.getElementById('kpSongRow').style.display = d.song ? 'flex' : 'none';
    document.getElementById('kpName').textContent = pretty(d.name);
    document.getElementById('kpRel').textContent = d.rel ? pretty(d.rel) : '';
    document.getElementById('kpWeekly').style.display = d.manual ? 'block' : 'none';
    var st = document.getElementById('kpStrip'), lt = document.getElementById('kpLetters');
    st.style.display = 'none'; lt.style.display = 'none';
    var view = d.peek ? 1 : d.stage;
    if (view === 1) strip(d, 2, 19, 58, true);
    else if (view === 2) strip(d, 1, 17, 36, false);
    if (view === 2 || view === 3) {
      var held = {}; d.held.forEach(function (pc) { held[pc] = true; });
      var order = d.pcs.map(function (pc, i) { return [pc, d.names[i] ]; });
      var start = order.findIndex(function (x) { return x[0] === d.tonic; });
      order = order.slice(start).concat(order.slice(0, start));
      lt.innerHTML = order.map(function (x) {
        return '<span class="' + (x[0] === d.tonic ? 'tonic ' : '') + (held[x[0] ] ? 'held' : '') + '">' + pretty(x[1]) + '</span>';
      }).join('');
      lt.style.display = 'flex';
    }
    document.getElementById('kpHoldLbl').textContent = d.hold ? (d.past ? 'LAST' : 'HOLDING') : '';
    document.getElementById('kpHold').textContent = d.hold ? pretty(d.hold) : '';
    var m = document.getElementById('kpMuted');
    if (d.mutedName) { m.textContent = pretty(d.mutedName) + ' muted'; m.style.opacity = 1; }
    else { m.style.opacity = 0; }
    Guard.fit(document.getElementById('kpHint'), d.hintParts || [d.hint]);
    send({ type: 'kpHeight', h: kp.offsetHeight });
  }
  function keyOff() {
    document.getElementById('kp').style.display = 'none';
    document.getElementById('panel').style.display = 'block';
  }
</script></body></html>
]]

-- Palette roles (Tweaks → "Slub palette"); fallbacks are the Apothecary seeds.
local function pageHtml()
  local ok, p = pcall(require, "modules.slub_palette")
  local seeds = ok and p.seeds and p.seeds() or nil
  local accent = seeds and seeds.accent or "#adcd4a"
  local danger = seeds and seeds.danger or "#7a001d"
  return require("modules.guard_kit").inject((HTML:gsub("@ACCENT@", accent):gsub("@DANGER@", danger)))
end

M.pageHtml = pageHtml   -- test hook: render the page in a browser

-- ── Key of the week (piano key-lock on) ───────────────────────────────────────
-- While modules/piano_lock.lua mutes out-of-key notes, the panel becomes a keyboard
-- strip for the active note set. The strip shrinks per key as you learn it
-- (modules/key_familiarity.lua): 1 new = two octaves with letters, 2 learning = one
-- octave + letters, 3 familiar = letters only, 4 known = key name only. A muted note
-- flashes on the strip and pops the full strip back for PEEK seconds.
local okLock, lock = pcall(require, "scale_lock")
local fam = require("modules.key_familiarity")
fam.load()
local FIFTHS = { "C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F" }
local FIFTH_PC = { 0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5 }

local function lockState()
  if not okLock then return nil end
  local ok, st = pcall(lock.getState)
  if not ok or type(st) ~= "table" or st.mode == "off" or not st.pitchClasses then return nil end
  return st
end

-- Song title without version tags ("(Remastered 2011)", "- 2011 Remaster", "[Live]"), so the name fits.
function M.shortTitle(t)
  t = tostring(t or "")
  local tags = { "remaster", "live", "version", "mono", "stereo", "edit", "mix", "deluxe", "bonus", "single", "demo" }
  local function isTag(x) x = x:lower(); for _, k in ipairs(tags) do if x:find(k, 1, true) then return true end end return false end
  t = t:gsub("%s*[%(%[]([^%)%]]*)[%)%]]", function(x) return isTag(x) and "" or nil end)
  t = t:gsub("%s+%-%s+(.+)$", function(x) return isTag(x) and "" or nil end)
  return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ── Follow the song (modules/song_key.lua) ─────────────────────────────────────
-- While music with a known key plays on the Mac, the lock and the panel switch to the
-- song's key. When the song stops, the song key stays while you keep playing; after
-- SONG_HOLD seconds with neither the song nor a piano note, it goes back to what was
-- there before (the weekly key, or your own pick).
local ASCII = { "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B" }
local song = { applied = nil, title = nil, last = 0, before = nil }

local function followSong()
  local st = lockState()
  if not st then return end
  local sk = package.loaded["modules.song_key"]
  local k = sk and sk.currentKey and sk.currentKey() or nil
  local now = hs.timer.secondsSinceEpoch()
  if k then
    local title = k.title or ""
    song.last, song.title = now, M.shortTitle(title)
    local name = ASCII[k.tonic + 1] .. " " .. k.mode
    if song.applied ~= name and song.want ~= name then
      if not song.applied then song.before = st.mode == "manual" and st.current or "weekly" end
      song.want = name
      local ok, canonical = lock.setScale(name)
      if ok then song.applied = canonical; print("🎹 piano_hud: following the song's key, " .. canonical)
      else print("⚠️ piano_hud: can't follow song key " .. name .. ": " .. tostring(canonical)) end
    end
  elseif song.applied then
    local idle = math.min(now - song.last, now - state.lastEvent)
    if idle >= T("song.holdSec") then
      -- Only undo our own switch: if you picked a key since, leave it.
      if st.mode == "manual" and st.current == song.applied then lock.setScale(song.before or "weekly") end
      print("🎹 piano_hud: song key over, back to " .. tostring(song.before))
      song.applied, song.want, song.title, song.before = nil, nil, nil, nil
    end
  end
end

local function syncFamConfig()
  fam.config.learningMinutes = T("learn.learningMinutes")
  fam.config.familiarMinutes = T("learn.familiarMinutes")
  fam.config.knownMinutes = T("learn.knownMinutes")
  fam.config.known = T("learn.knownKeys")
end

-- Window frame: the panel alone, or the panel plus the card above it. The panel's
-- bottom-right corner stays put either way (the page anchors it bottom-right).
-- Anchored at the "piano_hud" slot in hud_slots.json; the card grows into "piano_card".
local move = require("modules.hud_move")
local function slotRect(w, h)
  -- Where Matt last dragged it (any display), pinned at its bottom-right corner; else the slot.
  return move.anchored("piano_hud", w, h) or layout.rect("piano_hud", w, h)
end
local function hudRect()
  if state.keyMode then
    return slotRect(CFG.WIDTH, math.max(60, state.kpHeight or CFG.HEIGHT))
  end
  local w, h = CFG.WIDTH, CFG.HEIGHT
  if state.cardOpen and state.cardHeight > 0 then
    w = math.max(CFG.WIDTH, CFG.CARD_WIDTH)
    h = CFG.HEIGHT + CFG.CARD_GAP + state.cardHeight
  end
  return slotRect(w, h)
end
-- Puts the window at hudRect(), except mid-drag (the mouse owns it then).
local function place(wv)
  if wv and not move.dragging("piano_hud") then wv:frame(hudRect()) end
end

local render, closeCard, hideHud

-- Writes the latest session to ~/Documents/Piano Log/MIDI/ and selects it in Finder.
-- The converter runs as a task so the main thread (and every key tap) never waits on it.
local SAVE_SCRIPT = os.getenv("HOME") .. "/.hammerspoon/bin/piano-session-midi"

function M.saveMidi(done)
  flush()   -- the newest notes are still in the buffer
  state.lastEvent = hs.timer.secondsSinceEpoch()   -- don't fade out mid-save
  local function report(text)
    local wv = activeWatchers.pianoHudView
    if wv and state.ready then wv:evaluateJavaScript("saved(" .. hs.json.encode({ text = text }) .. ")") end
    if done then done(text) end
  end
  local task = hs.task.new(SAVE_SCRIPT, function(code, out, err)
    activeWatchers.pianoHudSave = nil
    if code == 0 then
      report("Saved ✓")
    else
      print("⚠️ piano_hud: save failed: " .. tostring(err))
      report((err or ""):find("No notes") and "No notes yet" or "Save failed")
    end
  end, { "--reveal" })
  activeWatchers.pianoHudSave = task
  if not task:start() then activeWatchers.pianoHudSave = nil; report("Save failed") end
end

local function onMessage(msg)
  local body = msg and msg.body or {}
  if body.type == "saveMidi" then
    M.saveMidi()
  elseif body.type == "toggle" then
    if state.cardOpen then closeCard() else M.openCard() end
  elseif body.type == "kpHeight" then
    state.kpHeight = tonumber(body.h) or state.kpHeight
    if state.keyMode then place(activeWatchers.pianoHudView) end
  elseif body.type == "dragStart" and activeWatchers.pianoHudView then
    move.begin("piano_hud", activeWatchers.pianoHudView, { onEnd = function(_, didMove)
      if didMove then state.lastEvent = hs.timer.secondsSinceEpoch() end
    end })
  elseif body.type == "dragReset" and activeWatchers.pianoHudView then
    move.reset("piano_hud")
    activeWatchers.pianoHudView:frame(hudRect())
  elseif body.type == "kpX" then
    M.dismiss()
  elseif (body.type == "kpPrev" or body.type == "kpNext") and okLock then
    local st = lockState()
    local i = 1
    for k, pc in ipairs(FIFTH_PC) do if st and pc == st.root then i = k end end
    i = ((i - 1 + (body.type == "kpNext" and 1 or -1)) % 12) + 1
    lock.setScale(FIFTHS[i] .. " major")
    state.lastEvent = hs.timer.secondsSinceEpoch()
  elseif body.type == "kpWeekly" and okLock then
    lock.setScale("weekly")
    state.lastEvent = hs.timer.secondsSinceEpoch()
  elseif body.type == "cardHeight" and state.cardOpen then
    state.cardHeight = tonumber(body.h) or 0
    place(activeWatchers.pianoHudView)
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
    :html(pageHtml())
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
  local st = lockState()
  if st then return M.keyRender(st) end
  if state.keyMode then
    state.keyMode = false
    wv:evaluateJavaScript("keyOff()")
    place(wv)
  end
  c, past = state.shown, state.shownPast
  local d = c and { name = c.name, detail = c.detail, notes = c.notes, past = past }
    or { name = "–", detail = "", notes = "", past = false }
  wv:evaluateJavaScript("update(" .. hs.json.encode(d) .. ")")
  if state.cardOpen then M.openCard() end
end

local HINTS = {   -- { stage, extra }; the extra is dropped first when the panel has no room
  { "New key", "shrinks as you learn it" },
  { "Learning" },
  { "Familiar", "keys pop back if you slip" },
  { "Known key" },
}

-- Draws the key-of-the-week panel for scale_lock state st.
function M.keyRender(st)
  local wv = activeWatchers.pianoHudView
  if not wv or not state.ready then return end
  syncFamConfig()
  local now = hs.timer.secondsSinceEpoch()
  local inSet = {}
  for _, pc in ipairs(st.pitchClasses) do inSet[pc] = true end
  local heldPcs, inKeyHeld, seen = {}, {}, {}
  for _, n in pairs(state.held) do
    local pc = n % 12
    if inSet[pc] then
      inKeyHeld[#inKeyHeld + 1] = n
      if not seen[pc] then seen[pc] = true; heldPcs[#heldPcs + 1] = pc end
    end
  end
  local hold, past = nil, false
  if #inKeyHeld > 0 then
    local c = M.nameChord(inKeyHeld); hold = c and c.name
  elseif state.shown and state.shownPast then
    hold, past = state.shown.name, true
  end
  local info = fam.info(st.pitchClasses)
  local muted = state.muted and now < state.muted.untilT and state.muted.pc or nil
  local name, rel = tostring(st.current or ""):match("^(.-)%s*/%s*(.+)$")
  -- Hint parts in priority order (the panel drops whole parts from the end, never cuts a word).
  local stage = HINTS[info.stage] or HINTS[1]
  local hintParts = { stage[1] }
  if info.minutes > 0 then
    hintParts[#hintParts + 1] = info.minutes .. " min"
    -- Most recent notes outside this key but fitting another one: say which, not "% wrong".
    local other = fam.otherKey(st.pitchClasses)
    if other then hintParts[#hintParts + 1] = "sounds like " .. other.name
    elseif info.notes > 20 then hintParts[#hintParts + 1] = info.wrongPct .. "% wrong" end
  end
  if stage[2] then hintParts[#hintParts + 1] = stage[2] end
  local hint = table.concat(hintParts, " · ")
  local d = {
    label = (song.applied and st.current == song.applied) and "Song key"
      or st.mode == "manual" and "Your pick" or ("Week " .. ((st.week or 0) + 1) .. " key"),
    name = name or st.current, rel = rel, manual = st.mode == "manual",
    pcs = st.pitchClasses, names = st.noteNames, tonic = st.root,
    held = heldPcs, stage = info.stage, peek = state.peekUntil ~= nil and now < state.peekUntil,
    muted = muted, mutedName = muted and noteName(muted) or nil,
    hold = hold, past = past, hint = hint, hintParts = hintParts,
    song = (song.applied and st.current == song.applied) and song.title or nil,
  }
  state.keyMode = true
  wv:evaluateJavaScript("keyUpdate(" .. hs.json.encode(d) .. ")")
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
    place(wv)
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

local function stopEscWatch()
  if activeWatchers.pianoHudEsc then activeWatchers.pianoHudEsc:stop(); activeWatchers.pianoHudEsc = nil end
end

local function showHud()
  if state.visible then return end
  local wv = ensureHud()
  place(wv)
  wv:show(CFG.FADE)
  state.visible = true
  -- Esc closes the key panel (never swallowed: the key still reaches the app in front).
  stopEscWatch()
  activeWatchers.pianoHudEsc = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if state.keyMode and not state.cardOpen and e:getKeyCode() == hs.keycodes.map.escape then
      hs.timer.doAfter(0, M.dismiss)
    end
    return false
  end):start()
end

-- Closes the HUD until the next note that follows DISMISS_QUIET seconds of silence.
function M.dismiss()
  state.dismissed = true
  hideHud()
end

function hideHud()
  stopEscWatch()
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
  local now = hs.timer.secondsSinceEpoch()
  local quiet = now - state.lastEvent
  state.lastEvent = now
  local isOn = cmd == "noteOn" and vel > 0
  if state.dismissed and isOn and quiet >= CFG.DISMISS_QUIET then state.dismissed = false end
  if not state.dismissed then showHud() end
  if isOn then
    local st = lockState()
    if st then
      local inKey = lock.isAllowed(note)
      if devName ~= "simulated" then fam.record(st.pitchClasses, inKey, now, st.current); fam.notePlayed(note, st.pitchClasses) end
      if not inKey then
        state.muted = { pc = note % 12, untilT = now + CFG.MUTED_HOLD }
        if fam.stage(st.pitchClasses) >= 2 then state.peekUntil = now + CFG.PEEK end
        if activeWatchers.pianoHudMuteTimer then activeWatchers.pianoHudMuteTimer:stop() end
        activeWatchers.pianoHudMuteTimer = hs.timer.doAfter(CFG.MUTED_HOLD + 0.05, function()
          activeWatchers.pianoHudMuteTimer = nil
          if state.visible then render() end
        end)
        if state.peekUntil and state.peekUntil > now then
          if activeWatchers.pianoHudPeekTimer then activeWatchers.pianoHudPeekTimer:stop() end
          activeWatchers.pianoHudPeekTimer = hs.timer.doAfter(CFG.PEEK + 0.05, function()
            activeWatchers.pianoHudPeekTimer = nil
            if state.visible then render() end
          end)
        end
      end
    end
  end
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
    fam.save()
    followSong()
    if state.visible and hs.timer.secondsSinceEpoch() - state.lastEvent > CFG.IDLE_HIDE then
      state.held = {}
      hideHud()
    end
  end)

  if okLock then
    lock.on("piano_hud", function()
      hs.timer.doAfter(0, function() if state.visible then render() end end)
    end)
  end

  activeWatchers.pianoHudScreens = hs.screen.watcher.new(function()
    place(activeWatchers.pianoHudView)
  end):start()
end

function M.stop()
  flush()
  fam.save()
  stopCardWatch()
  stopEscWatch()
  if okLock then lock.off("piano_hud") end
  for _, k in ipairs({ "pianoHudMuteTimer", "pianoHudPeekTimer" }) do
    if activeWatchers[k] then activeWatchers[k]:stop(); activeWatchers[k] = nil end
  end
  state.keyMode, state.dismissed, state.muted, state.peekUntil = false, false, nil, nil
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
           keyMode = state.keyMode or false, dismissed = state.dismissed or false,
           shown = state.shown and state.shown.name, past = state.shownPast,
           frame = f and string.format("%d,%d %dx%d", f.x, f.y, f.w, f.h) }
end

return M
