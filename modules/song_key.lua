-- ~/.hammerspoon/modules/song_key.lua
-- Song key HUD (step 1 of the live key detector: web lookup only, no audio analysis).
--
--   • Every POLL seconds asks nowplaying-cli what's playing (Apple Music, Spotify,
--     browsers… anything that shows in the Now Playing widget), whatever the output
--     device and whether or not Ableton is open.
--   • On a new song, runs bin/song-key, which looks the key up on Hooktheory
--     (human transcriptions, with modes per section) and falls back to AcousticBrainz.
--   • Pill first (Matt, 2026-11-09): when a song counts, a thin "KEY  E maj" pill appears at the
--     bottom edge (slot "song_key_pill"). Resting the mouse on it pops the full card up above it
--     (key, sections, keyboard, what the ear hears; the "song_key" slot), and moving away shrinks
--     it back. A click on the pill, or ⌃⌥⌘K, keeps the card open until × / ⌃⌥⌘K / "show.seconds".
--     The pill's own × hides it until the next song. It drags like a window (modules/hud_move.lua,
--     one saved spot: the pill's bottom-right corner); double-click the card's top row or the
--     pill's label to send it home.
--     The pill is built to move into the planned bottom bar (Dock replacement): M.pillState()
--     gives what it shows, M.openCard() is what a click does (IDEAS.md, "Song key pill").
--     It fades out PAUSE_HIDE seconds after playback stops.
--   • Music only: the listener measures how often the sound drops out (speech pauses
--     between words, music doesn't), so a spoken reel, podcast or video never brings it
--     up. Apple Music and Spotify tracks found online show at once; anything else
--     waits until the ear hears music, and speech hides it again.
--   • Built on Slub Guard (modules/guard_kit.lua): solid panel, light and dark, palette colours.
--   Feel knobs: ~/.hammerspoon/tweaks/song_key.json, or the Tweaks panel (⌃⌥⌘T).
--   Preview without music: hs -c 'require("modules.song_key").preview("card")'  ("pill", nil = back to live)

local M = {
  id = "song_key",
  name = "Song Key HUD"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers
local layout = require("modules.hud_layout")

local CFG = {
  POLL       = 4,      -- seconds between now-playing checks
  PAUSE_HIDE = 20,     -- seconds after playback stops before it fades
  FADE       = 0.3,
  WIDTH      = 240,
  HEIGHT     = 148,
  PILL_W     = 104,
  PILL_H     = 22,
  GAP        = 1,      -- between the card and the pill under it
  HOTKEY     = { { "ctrl", "alt", "cmd" }, "K" },   -- shown on the card as ⌃⌥⌘K
  NOWPLAYING = "/usr/local/bin/nowplaying-cli",
  LOOKUP     = os.getenv("HOME") .. "/.hammerspoon/bin/song-key",
  LISTEN     = os.getenv("HOME") .. "/.hammerspoon/bin/song-key-listen",
  LISTEN_DEVICE = nil,   -- nil = all system audio (audiotee); or an input device name
  SMOOTH     = 3,      -- listener readings averaged for the ear check
}
M.config = CFG

local T = hs and require("modules.tweaks").open{
  app = "Song Key HUD",
  file = require("modules.tweaks").dir .. "/song_key.json",
  knobs = {
    ["ear.speechLer"] = { 0.3, min = 0.15, max = 0.6, step = 0.01, note = "Pause share at or above which the sound counts as speech" },
    ["show.seconds"]  = { 90, min = 0, max = 600, step = 5, note = "Seconds a card you opened by click or ⌃⌥⌘K stays before shrinking back to the pill (0 = until you close it)" },
    ["hover.openDelay"]  = { 0.25, min = 0, max = 1.5, step = 0.05, note = "Seconds the mouse rests on the pill before the card pops up" },
    ["hover.closeDelay"] = { 0.5, min = 0, max = 3, step = 0.1, note = "Seconds after the mouse leaves before a hover card shrinks back" },
  },
}

-- Apps whose audio is never a song (reels in the Claude app).
local IGNORE = { ["com.anthropic.claudefordesktop"] = true }
-- Music Connect (MusicKit) plays through Apple's XPC helper, so Now Playing names that helper. Its
-- .xpc bundle resolves to an app path, so the ear already taps the helper's own process.
local TRUSTED = { ["com.apple.Music"] = true, ["com.spotify.client"] = true,
  ["com.apple.MediaPlayer.RemotePlayerService"] = true }

-- Sources heard through an input device instead of a process tap. AirPlay Receiver
-- plays inside Control Center, and Matt's Loopback device "Airplay Receiver" takes that
-- audio (muting it to the speakers), so a tap on Control Center hears only silence.
local DEVICE_FOR = { ["com.apple.controlcenter"] = "Airplay Receiver" }

local state = {
  song = nil,        -- "artist|title" currently shown or being looked up
  result = nil,      -- last song-key JSON
  playing = false,
  lastPlaying = 0,
  mode = nil,        -- nil (hidden) | "card" | "pill"
  ready = false,
  pending = nil,     -- data waiting for the page to load
  ear = {},          -- recent listener readings (newest last)
  source = nil,      -- path of the app the ear listens to (nil = all system audio)
  earStatus = nil,   -- "listening" | "quiet" | "error" while there is no usable reading
  bundle = nil,      -- bundle ID of the app playing
  pinned = false,    -- card opened by click / ⌃⌥⌘K (stays when the mouse leaves)
  hiddenFor = nil,   -- song whose pill was closed too; nothing shows until the next song
  preview = nil,     -- test data shown by M.preview (poll paused)
}

local HTML = [==[
<!doctype html><html><head><meta charset="utf-8">@GUARD@<style>
  html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; -webkit-user-select: none; cursor: default; }
  /* Both pinned to the window's corners: the window grows up and left from the pill. */
  #card { display: none; position: absolute; left: 0; top: 0; width: @CW@px; height: @CH@px; box-sizing: border-box; }
  #pill { display: flex; position: absolute; right: 0; bottom: 0; width: @PW@px; height: @PH@px; box-sizing: border-box; }
  body.card #card { display: flex; animation: pop 0.12s ease-out; }
  @keyframes pop { from { opacity: 0; } to { opacity: 1; } }
  #card { gap: 4px; }
  #card .g-hint.title { padding-left: 2px; }
  .low #key, .low #kb { opacity: 0.7; }
  #kb { display: block; width: 100%; height: 32px; flex-shrink: 0; }
  /* Keyboard: in-key keys full white/black, the rest muted, home note(s) in the accent. */
  #kb .w { fill: var(--g-sunk); stroke: var(--g-line); stroke-width: 1; }
  #kb .w.in { fill: var(--g-key-white); }
  #kb .b { fill: var(--g-line-strong); }
  #kb .b.in { fill: var(--g-key-black); }
  @media (prefers-color-scheme: dark) { #kb .w { fill: var(--g-faint); } #kb .b { fill: var(--g-line); }
    #kb .w.in { fill: var(--g-key-white); } #kb .b.in { fill: var(--g-key-black); } }
  .g-dark #kb .w { fill: var(--g-faint); } .g-dark #kb .b { fill: var(--g-line); }
  .g-dark #kb .w.in { fill: var(--g-key-white); } .g-dark #kb .b.in { fill: var(--g-key-black); }
  /* Home note(s) last, so they win in both schemes. */
  #kb rect.w.tonic, #kb rect.b.tonic, .g-dark #kb rect.tonic { fill: var(--g-accent); }
  /* Pill: one line, solid, the × shows on hover (visibility, so nothing shifts). */
  #pill { align-items: center; gap: 6px; padding: 0 3px 0 9px; background: var(--g-panel);
    border: 1px solid var(--g-line-strong); border-radius: 11px; }
  #pill .g-label { line-height: 20px; }
  #pillKey { font: 600 12.5px/20px var(--g-font-round); color: var(--g-text); flex: 1 1 auto; min-width: 0; white-space: nowrap; overflow: hidden; }
  #pillX { width: 16px; height: 16px; font-size: 13px; line-height: 16px; border-radius: 8px; visibility: hidden; }
  #pill:hover #pillX, body.hov #pillX { visibility: visible; }
</style></head><body class="g">
<div id="card" class="g-panel">
  <div class="g-row h18" id="top"><span class="g-label g-keep">Song key</span>
    <span class="g-hint g-give title" id="title"></span><span class="g-grow"></span>
    <span class="g-kbd" title="Keep the card open, or shrink it back to the pill">⌃⌥⌘K</span>
    <button class="g-icon" id="x" title="Shrink back to the pill (⌃⌥⌘K)">×</button></div>
  <div class="g-row h28"><span class="g-title g-live" id="key">…</span><span class="g-grow"></span>
    <button class="g-icon" id="open" title="Open on Hooktheory">↗</button></div>
  <div class="g-row h18"><span class="g-sub g-live" id="sub">&nbsp;</span></div>
  <svg id="kb" viewBox="0 0 208 32" preserveAspectRatio="none"></svg>
  <div class="g-row h18"><span class="g-hint g-live" id="ear">&nbsp;</span></div>
</div>
<div id="pill" title="Song key. Hover for the full card, click to keep it open (⌃⌥⌘K), drag to move">
  <span class="g-label g-keep" id="pillLabel">Key</span><span id="pillKey">…</span>
  <button class="g-icon" id="pillX" title="Hide until the next song">×</button>
</div><script>
  // Scale steps from the tonic, by the mode word in the key name.
  var MODES = { major: [0,2,4,5,7,9,11], ionian: [0,2,4,5,7,9,11], dorian: [0,2,3,5,7,9,10],
    phrygian: [0,1,3,5,7,8,10], lydian: [0,2,4,6,7,9,11], mixolydian: [0,2,4,5,7,9,10],
    minor: [0,2,3,5,7,8,10], aeolian: [0,2,3,5,7,8,10], locrian: [0,1,3,5,6,8,10],
    harmonic: [0,2,3,5,7,8,11], phrygiandominant: [0,1,4,5,7,8,10] };
  var TONIC = { C:0, D:2, E:4, F:5, G:7, A:9, B:11 };
  function parseKey(k) {
    var m = /^([A-G])([#♯b♭]?)\s+(.*)$/.exec(k || '');
    if (!m) return null;
    var t = TONIC[m[1]] + (/[#♯]/.test(m[2]) ? 1 : /[b♭]/.test(m[2]) ? -1 : 0);
    var mode = m[3].toLowerCase().replace(/[^a-z]/g, '');
    if (mode.indexOf('harmonicminor') === 0) mode = 'harmonic';
    return { tonic: (t + 12) % 12, steps: MODES[mode] || null };
  }
  // Two octaves, C to B: scale notes full white/black, the home note in the accent.
  function drawKeys(k, alt) {
    var p = parseKey(k), inScale = {}, svg = '', W = 208 / 14;
    if (p) (p.steps || [0]).forEach(function (s) { inScale[(p.tonic + s) % 12] = true; });
    var whites = [0,2,4,5,7,9,11], blacks = { 1:1, 3:2, 6:4, 8:5, 10:6 };
    var altTonic = alt == null ? -1 : alt;
    function cls(pc, c) { return c + (p && (pc === p.tonic || pc === altTonic) ? ' tonic' : inScale[pc] ? ' in' : ''); }
    for (var o = 0; o < 2; o++) whites.forEach(function (pc, i) {
      svg += '<rect class="' + cls(pc, 'w') + '" x="' + ((o * 7 + i) * W + 0.5) + '" y="0.5" width="' + (W - 1) + '" height="31" rx="2"/>';
    });
    for (var o2 = 0; o2 < 2; o2++) for (var pc in blacks) {
      svg += '<rect class="' + cls(+pc, 'b') + '" x="' + ((o2 * 7 + blacks[pc]) * W - W * 0.3) + '" y="0" width="' + (W * 0.6) + '" height="19" rx="1.5"/>';
    }
    document.getElementById('kb').innerHTML = svg;
  }
  function post(m) { try { webkit.messageHandlers.songKey.postMessage(m); } catch (err) {} }
  function setText(id, s) {
    var el = document.getElementById(id);
    if (window.Guard && Guard.text) Guard.text(el, s); else el.textContent = s;
  }
  // Hover is tracked in Lua from the mouse position (watchMouse): this window belongs to
  // Hammerspoon, which is never the active app, so the page gets no mouse-move events.
  // Buttons act on click and never start a drag; anything else drags (shared hud_move).
  ['x', 'open', 'pillX'].forEach(function (id) {
    var b = document.getElementById(id);
    b.addEventListener('mousedown', function (e) { e.stopPropagation(); });
    b.addEventListener('click', function (e) { e.stopPropagation(); post({ type: id }); });
  });
  // A press that ends where it started (screen coordinates, so a moved window counts as
  // moved) is a click: on the pill it opens the card. Decided here, not in the drag tap,
  // so a quick click can't race the drag.
  var downAt = null;
  ['card', 'pill'].forEach(function (id) {
    document.getElementById(id).addEventListener('mousedown', function (e) {
      if (e.button !== 0) return;
      downAt = { x: e.screenX, y: e.screenY };
      post({ type: 'dragStart', what: id });
    });
  });
  document.getElementById('pill').addEventListener('mouseup', function (e) {
    if (e.button !== 0 || !downAt || e.target.id === 'pillX') return;
    var moved = Math.abs(e.screenX - downAt.x) + Math.abs(e.screenY - downAt.y);
    downAt = null;
    if (moved < 4) post({ type: 'pillClick' });
  });
  document.getElementById('top').addEventListener('dblclick', function () { post({ type: 'dragReset', what: 'card' }); });
  document.getElementById('pillLabel').addEventListener('dblclick', function () { post({ type: 'dragReset', what: 'pill' }); });
  function update(d) {
    var cls = 'g ' + (d.mode || 'pill') + (d.dark ? ' g-dark' : '') + (document.body.classList.contains('hov') ? ' hov' : '');
    if (document.body.className !== cls) document.body.className = cls;
    setText('title', d.title || '');
    setText('key', d.key || '…');
    setText('sub', d.sub || ' ');
    setText('ear', d.ear || ' ');
    setText('pillKey', d.pill || '…');
    document.getElementById('card').classList.toggle('low', !!d.low);
    document.getElementById('open').style.visibility = d.url ? 'visible' : 'hidden';
    drawKeys(d.kb || d.key, d.altTonic);
  }
</script></body></html>
]==]

-- Slub Guard CSS/JS and the palette seeds go into the page.
local function pageHtml()
  local html = HTML:gsub("@CW@", CFG.WIDTH):gsub("@CH@", CFG.HEIGHT):gsub("@PW@", CFG.PILL_W):gsub("@PH@", CFG.PILL_H)
  return require("modules.guard_kit").inject(html)
end
M.pageHtml = pageHtml   -- test hook: render the page in a browser

-- Reserved slots in hud_slots.json: "song_key_pill" at the bottom edge, "song_key" above it for
-- the card. One window: the pill alone, or the card stacked on the pill. Both share the pill's
-- bottom-right corner, which is also where a drag is remembered.
local move = hs and require("modules.hud_move")
local SPOT = "song_key_pill"
local function rect(mode)
  mode = mode or state.mode or "pill"
  local w, h = CFG.PILL_W, CFG.PILL_H
  if mode == "card" then w, h = CFG.WIDTH, CFG.HEIGHT + CFG.GAP + CFG.PILL_H end
  local saved = move.anchored(SPOT, w, h)
  if saved then return saved end
  local p = layout.rect(SPOT, CFG.PILL_W, CFG.PILL_H)
  return hs.geometry.rect(p.x + p.w - w, p.y + p.h - h, w, h)
end

local startListener, stopListener   -- defined with the listener below
local redraw                        -- defined after describe()

local function draw(d)
  state.pending = d
  local wv = activeWatchers.songKeyView
  if wv and state.ready then wv:evaluateJavaScript("update(" .. hs.json.encode(d) .. ")") end
end

local collapse, hide, M_openCard, hidePill, peek, stopTimers   -- defined below

local function onMessage(msg)
  local body = msg and msg.body or {}
  local wv = activeWatchers.songKeyView
  if body.type == "open" and state.result and state.result.url then
    hs.urlevent.openURL(state.result.url)
  elseif body.type == "x" then
    collapse()
  elseif body.type == "pillX" then
    hidePill()
  elseif body.type == "hover" then
    state.hovering = true
    if activeWatchers.songKeyLeave then activeWatchers.songKeyLeave:stop(); activeWatchers.songKeyLeave = nil end
    -- Resting on the pill pops the card up (after hover.openDelay).
    if body.pill and state.mode == "pill" and not activeWatchers.songKeyPeek then
      activeWatchers.songKeyPeek = hs.timer.doAfter(T and T("hover.openDelay") or 0.25, function()
        activeWatchers.songKeyPeek = nil
        if state.hovering and state.mode == "pill" and not move.dragging(SPOT) then peek() end
      end)
    end
  elseif body.type == "unhover" then
    state.hovering = false
    if activeWatchers.songKeyPeek then activeWatchers.songKeyPeek:stop(); activeWatchers.songKeyPeek = nil end
    -- A hover card shrinks back once the mouse has been gone hover.closeDelay.
    if state.mode == "card" and not state.pinned and not activeWatchers.songKeyLeave then
      activeWatchers.songKeyLeave = hs.timer.doAfter(T and T("hover.closeDelay") or 0.5, function()
        activeWatchers.songKeyLeave = nil
        if not state.hovering and not state.pinned and not move.dragging(SPOT) then collapse() end
      end)
    end
  elseif body.type == "dragStart" and wv then
    -- A quick click can be over before this message lands; a drag started then would wait for
    -- the next mouse-up anywhere and move the HUD with whatever you drag next.
    if next(hs.eventtap.checkMouseButtons()) ~= nil then move.begin(SPOT, wv) end
  elseif body.type == "pillClick" then
    if state.mode == "card" and state.pinned then collapse() else M_openCard() end
  elseif body.type == "dragReset" and wv then
    move.reset(SPOT)
    wv:frame(rect())
  end
end

local function ensureView()
  if activeWatchers.songKeyView then return activeWatchers.songKeyView end
  state.ready = false
  local uc = hs.webview.usercontent.new("songKey"):setCallback(onMessage)
  local wv = hs.webview.new(rect(), { developerExtrasEnabled = false }, uc)
  wv:navigationCallback(function(action)
    if action == "didFinishNavigation" then
      state.ready = true
      if state.pending then draw(state.pending) end
    end
  end)
  wv:windowStyle({ "borderless", "nonactivating" })
    :transparent(true)
    :shadow(false)
    :level(hs.drawing.windowLevels.floating)
    :behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
    :allowTextEntry(false)
    :html(pageHtml())
  activeWatchers.songKeyView = wv
  return wv
end

function stopTimers()
  for _, k in ipairs({ "songKeyAutoHide", "songKeyPeek", "songKeyLeave" }) do
    if activeWatchers[k] then activeWatchers[k]:stop(); activeWatchers[k] = nil end
  end
end

-- Hover from the mouse position, 10 times a second while it's up (Hammerspoon is never the
-- active app, so its webviews get no mouse-move events). Only counts once the mouse has
-- moved since it appeared, so a pill that shows up under a resting cursor stays a pill.
local function watchMouse()
  if activeWatchers.songKeyMouse then return end
  local start, armed = hs.mouse.absolutePosition(), false
  state.onPill = false
  activeWatchers.songKeyMouse = hs.timer.doEvery(0.1, function()
    local wv = activeWatchers.songKeyView
    if not (wv and state.mode) or move.dragging(SPOT) then return end
    local p = hs.mouse.absolutePosition()
    if not armed then armed = math.abs(p.x - start.x) + math.abs(p.y - start.y) > 2 end
    local f = wv:frame()
    local inside = armed and p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h
    local onPill = inside and p.x >= f.x + f.w - CFG.PILL_W and p.y >= f.y + f.h - CFG.PILL_H or false
    if inside then onMessage({ body = { type = "hover", pill = onPill } })
    elseif state.hovering then onMessage({ body = { type = "unhover" } }) end
    if onPill ~= state.onPill then
      state.onPill = onPill   -- shows the pill's ×
      wv:evaluateJavaScript("document.body.classList.toggle('hov', " .. tostring(onPill) .. ")")
    end
  end)
end

local function stopMouse()
  if activeWatchers.songKeyMouse then activeWatchers.songKeyMouse:stop(); activeWatchers.songKeyMouse = nil end
end

-- A pinned card's clock: shrinks back after show.seconds, waiting while the mouse is over it.
local function startCardTimer()
  local secs = T and T("show.seconds") or 90
  if secs <= 0 then return end
  activeWatchers.songKeyAutoHide = hs.timer.doAfter(secs, function()
    activeWatchers.songKeyAutoHide = nil
    if not state.hovering then return collapse() end
    activeWatchers.songKeyAutoHide = hs.timer.waitUntil(function() return not state.hovering end,
      function() activeWatchers.songKeyAutoHide = nil; collapse() end, 0.5)
  end)
end

-- Pill ↔ card in place: the pill never moves; the window grows up and left from its corner.
-- Growing: frame first, then the card appears. Shrinking: the card goes, then the frame.
local function switchTo(mode)
  if state.mode == mode then return end
  local wv = ensureView()
  local was = state.mode
  state.mode = mode
  if mode == "card" then
    if not move.dragging(SPOT) then wv:frame(rect()) end
    redraw()
  else
    redraw()
    if not move.dragging(SPOT) then wv:frame(rect()) end
  end
  if not was then wv:show(CFG.FADE); watchMouse() end
end

function hide()
  stopTimers()
  stopMouse()
  if not state.mode then return end
  if activeWatchers.songKeyView then activeWatchers.songKeyView:hide(CFG.FADE) end
  state.mode, state.pinned, state.hovering = nil, false, false
end

-- Card → pill (mouse left a hover card, ×, ⌃⌥⌘K, or a pinned card's time is up). The ear
-- rests again once the key is known.
function collapse()
  if state.mode ~= "card" then return end
  stopTimers()
  state.pinned = false
  switchTo("pill")
  if not state.preview and state.result and state.result.found then stopListener() end
end

-- Hover: the card pops up until the mouse leaves.
function peek()
  state.pinned = false
  switchTo("card")
end

-- Click on the pill, ⌃⌥⌘K, or later the bottom bar: the card stays open (show.seconds) and
-- the ear listens again for its live line.
function M_openCard()
  state.hiddenFor = nil
  stopTimers()
  state.pinned = true
  switchTo("card")
  startCardTimer()
  if not state.preview and state.playing and not activeWatchers.songKeyListen
     and not (state.bundle and IGNORE[state.bundle]) then startListener() end
end
M.openCard = M_openCard

-- The pill's ×: nothing until the next song (⌃⌥⌘K brings it back).
function hidePill()
  state.hiddenFor = state.song
  hide()
  stopListener()
end
M.hidePill = hidePill

-- ⌃⌥⌘K: card → pill, pill → pinned card, nothing showing but music playing → pinned card.
function M.toggle()
  if state.mode == "card" then collapse()
  elseif state.mode == "pill" or (state.playing and state.song) then M_openCard() end
end
-- ── Ear check (pure functions, testable with hs -c) ───────────────────────────
local STEPS = { major = { 0, 2, 4, 5, 7, 9, 11 }, ionian = { 0, 2, 4, 5, 7, 9, 11 },
  dorian = { 0, 2, 3, 5, 7, 9, 10 }, phrygian = { 0, 1, 3, 5, 7, 8, 10 },
  lydian = { 0, 2, 4, 6, 7, 9, 11 }, mixolydian = { 0, 2, 4, 5, 7, 9, 10 },
  minor = { 0, 2, 3, 5, 7, 8, 10 }, aeolian = { 0, 2, 3, 5, 7, 8, 10 },
  locrian = { 0, 1, 3, 5, 6, 8, 10 }, harmonic = { 0, 2, 3, 5, 7, 8, 11 } }
local LETTER = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

-- "A Dorian" / "F# minor" / "B♭ Major" → tonic pitch class, scale steps (nil if unknown mode).
function M.parseKey(k)
  local letter, acc, mode = (k or ""):match("^([A-G])([#b]?)%s+(.+)$")
  if not letter then
    letter, acc, mode = (k or ""):match("^([A-G])(\xE2\x99[\xAF\xAD]?)%s+(.+)$")   -- ♯ ♭
    if acc == "\xE2\x99\xAF" then acc = "#" elseif acc == "\xE2\x99\xAD" then acc = "b" end
  end
  if not letter then return nil end
  local t = LETTER[letter] + ((acc == "#") and 1 or (acc == "b") and -1 or 0)
  mode = mode:lower():gsub("[^a-z]", "")
  if mode:find("^harmonicminor") then mode = "harmonic" end
  return (t + 12) % 12, STEPS[mode]
end

local function energy(chroma, tonic, steps)
  local e = 0
  for _, st in ipairs(steps) do e = e + (chroma[((tonic + st) % 12) + 1] or 0) end
  return e
end

-- How well the heard pitch profile fits a key: its note set is ranked against the
-- 12 major-scale note sets. Best (or a near tie) = "fits"; beaten only by the two
-- neighbour keys (one sharp/flat away) = "close"; else "off". Returns verdict, fit, best.
function M.verdict(key, chroma)
  local tonic, steps = M.parseKey(key)
  if not tonic or not chroma or #chroma ~= 12 then return nil end
  steps = steps or STEPS.major
  local fit, best, beaten = energy(chroma, tonic, steps), 0, 0
  for t = 0, 11 do
    local e = energy(chroma, t, STEPS.major)
    best = math.max(best, e)
    if e > fit + 0.015 then beaten = beaten + 1 end
  end
  return (beaten == 0 and "fits") or (beaten <= 2 and "close") or "off", fit, best
end

-- Averages the last SMOOTH readings; returns { chroma, key, mode, strength } or nil.
function M.earSummary(readings)
  if not readings or #readings == 0 then return nil end
  local c, votes, n, strength = {}, {}, #readings, 0
  for i = 1, 12 do c[i] = 0 end
  for _, r in ipairs(readings) do
    for i = 1, 12 do c[i] = c[i] + (r.chroma[i] or 0) / n end
    votes[r.mode] = (votes[r.mode] or 0) + 1
    strength = strength + (r.strength or 0) / n
  end
  local last = readings[#readings]
  local mode, top = last.mode, votes[last.mode]
  for m, v in pairs(votes) do if v > top then mode, top = m, v end end
  return { chroma = c, key = last.key, mode = mode, stable = top >= math.min(2, n), strength = strength }
end

-- "music" | "speech" | nil (not sure yet) from the recent readings: at least two of the
-- last SMOOTH must agree. A reading's pause share (ler) at or above `speechLer` is speech.
function M.heard(readings, speechLer)
  if not readings or #readings == 0 then return nil end
  local speech, music = 0, 0
  for _, r in ipairs(readings) do
    if r.ler then
      if r.ler >= speechLer then speech = speech + 1 else music = music + 1 end
    end
  end
  local need = math.min(2, #readings)
  if music >= need and music > speech then return "music" end
  if speech >= need and speech >= music then return "speech" end
  return nil
end

-- Should the pill be up? Pure. Trusted players (Apple Music, Spotify) with the song
-- found online show at once; everything else waits for the ear to hear music. Speech
-- always hides it, and so does an ear that can't capture unless the song was found.
function M.shouldShow(o)
  if o.dismissed or o.ignored then return false end
  if o.heard == "speech" then return false end
  if o.heard == "music" then return true end
  return (o.trusted or o.earError) and o.found or false
end

local MAJ_NAME = { "C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B" }
local MIN_NAME = { "C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B" }

-- "A# major" → "B♭ major / G minor", the key for the keyboard, and the second
-- home note's pitch class. nil for anything that isn't plain major/minor.
function M.relativePair(key)
  local tonic, steps = M.parseKey(key)
  if not tonic then return nil end
  local isMajor = steps == STEPS.major
  if not isMajor and steps ~= STEPS.minor then return nil end
  local major = isMajor and tonic or (tonic + 3) % 12
  local minor = (major + 9) % 12
  local text = MAJ_NAME[major + 1] .. " major / " .. MIN_NAME[minor + 1] .. " minor"
  return text, MAJ_NAME[major + 1] .. " major", minor
end

-- Turns a song-key result (and the ear summary) into what the pill shows. Pure.
function M.describe(r, title, ear, earStatus)
  local label = "SONG KEY" .. (title and title ~= "" and ("  ·  " .. title:upper()) or "")
  local earLine
  if ear then
    earLine = "Live: hearing " .. ear.key
  elseif earStatus == "quiet" then earLine = "Live: quiet"
  elseif earStatus == "error" then earLine = "Live: can't capture audio"
  else earLine = "Live: listening…" end

  if not r then return { label = label, key = "Looking up…", sub = "", ear = earLine } end
  if not r.found then
    if ear and ear.stable then
      return { label = label, key = ear.mode, sub = "From live listening · not found online",
               ear = earLine, low = ear.strength < 0.75 }
    end
    return { label = label, key = "Key unknown", sub = "Not on Hooktheory or AcousticBrainz",
             ear = earLine, low = true }
  end
  local sub
  if r.source == "Hooktheory" then
    local parts = {}
    if r.keys and #r.keys > 1 then
      for _, s in ipairs(r.sections or {}) do
        if s.section:lower() ~= "all sections" then table.insert(parts, s.section .. " " .. s.key) end
      end
      sub = table.concat(parts, " · ")
    else
      sub = "Hooktheory · human transcription"
    end
  else
    sub = string.format("Online, computer-analysed · %d cop%s · %d%% agree", r.analyses or 0,
      (r.analyses == 1) and "y" or "ies", math.floor((r.agree or 0) * 100 + 0.5))
  end
  if ear then
    -- Any section key that fits counts (songs move between sections).
    local best = "off"
    for _, k in ipairs(r.keys or { r.key }) do
      local v = M.verdict(k, ear.chroma)
      if v == "fits" then best = "fits"; break elseif v == "close" then best = "close" end
    end
    earLine = (best == "fits" and "Live agrees ✓ · hearing " or best == "close" and "Live: close · hearing "
      or "Live disagrees · hearing ") .. ear.key
  end
  local d = { label = label, key = r.key, sub = sub, ear = earLine, low = r.confidence == "low", url = r.url }
  if r.source ~= "Hooktheory" then
    -- Computer analysis often mixes up a key and its relative (same notes), so
    -- show both and draw both home notes; Matt picks by ear.
    local key, kb, alt = M.relativePair(r.key)
    if key then d.key, d.kb, d.altTonic = key, kb, alt end
  end
  return d
end

local SHORT_MODE = { major = "maj", ionian = "maj", minor = "min", aeolian = "min", dorian = "dor",
  phrygian = "phr", lydian = "lyd", mixolydian = "mix", locrian = "loc", harmonicminor = "harm min",
  harmonic = "harm min", phrygiandominant = "phr dom" }

-- "E Major" → "E maj", "F♯ Dorian" → "F♯ dor", "B♭ major / G minor" → "B♭ maj". "?" if unknown. Pure.
function M.shortKey(key)
  key = (key or ""):gsub("%s*/.*$", "")
  local tonic, mode = key:match("^([A-G]\xE2\x99[\xAF\xAD])%s+(.+)$")
  if not tonic then tonic, mode = key:match("^([A-G][#b]?)%s+(.+)$") end
  if not tonic then return "?" end
  tonic = tonic:gsub("#", "♯"):gsub("^([A-G])b$", "%1♭")
  local m = mode:lower():gsub("[^a-z]", "")
  return tonic .. " " .. (SHORT_MODE[m] or mode:lower())
end

-- What the pill shows, for the pill here and later the bottom bar: { key = "E maj",
-- full = "E Major", title = "Alison", song = "artist|title" }, or nil when it isn't up.
function M.pillState()
  if state.mode ~= "pill" then return nil end
  local d = state.pending or {}
  return { key = d.pill, full = d.pillFull, title = d.title, song = state.song }
end

function redraw()
  if state.preview then
    local d = {}
    for k, v in pairs(state.preview) do d[k] = v end
    d.mode = state.mode or "pill"
    return draw(d)
  end
  local title = state.song and state.song:match("|(.*)$") or ""
  local ear = state.earStatus == nil and M.earSummary(state.ear) or nil
  local d = M.describe(state.result, title, ear, state.earStatus)
  local r = state.result
  local full = (r and r.found and r.key) or (ear and ear.stable and ear.mode) or nil
  if not full and not (r and r.found) then
    -- The ear may have stopped (pill): keep the last stable reading it had.
    local last = M.earSummary(state.ear)
    if last and last.stable then full = last.mode end
  end
  d.pill, d.pillFull, d.mode, d.title = full and M.shortKey(full) or "?", full, state.mode or "pill", title
  draw(d)
end

local function heardNow()
  return M.heard(state.ear, T and T("ear.speechLer") or 0.3)
end

-- Shows the card or the pill, or hides both, for what is playing and heard right now.
local function refresh()
  if not state.playing or state.preview then return end
  local o = {
    dismissed = state.hiddenFor ~= nil and state.hiddenFor == state.song,
    ignored = state.bundle and IGNORE[state.bundle] or false,
    heard = heardNow(),
    trusted = state.bundle and TRUSTED[state.bundle] or false,
    earError = state.earStatus == "error",
    found = state.result and state.result.found or false,
  }
  if M.shouldShow(o) then
    if not state.mode then switchTo("pill") end
    -- The pill only needs the key: once it's known, the ear rests until the card is pinned.
    if state.mode == "pill" and state.result and state.result.found then stopListener() end
  -- Once up, only speech (or a close) takes it down, so a quiet bar doesn't flicker it.
  elseif state.mode and (o.heard == "speech" or o.dismissed or o.ignored) then hide() end
end
-- The key of the music playing right now, for other modules (piano_hud follows it).
-- nil unless a song is playing and counts as music (same test as the pill, but a
-- closed pill still counts). Returns { key = "B♭ Major", tonic = 10, mode = "major",
-- title = "Song title", song = "artist|title" }; mode is a scale_lock mode name.
function M.currentKey()
  if not state.playing then return nil end
  local o = {
    dismissed = false,
    ignored = state.bundle and IGNORE[state.bundle] or false,
    heard = heardNow(),
    trusted = state.bundle and TRUSTED[state.bundle] or false,
    earError = state.earStatus == "error",
    found = state.result and state.result.found or false,
  }
  if not M.shouldShow(o) then return nil end
  local key = state.result and state.result.found and state.result.key or nil
  if not key then
    local ear = M.earSummary(state.ear)
    if ear and ear.stable then key = ear.mode end
  end
  local tonic, steps = M.parseKey(key)
  if not tonic or not steps then return nil end
  local mode = (key:match("^%S+%s+(.+)$") or "major"):lower():gsub("[^a-z ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if mode == "ionian" then mode = "major" elseif mode == "aeolian" then mode = "minor"
  elseif mode == "harmonic" or mode == "harmonicminor" then mode = "harmonic minor" end
  return { key = key, tonic = tonic, mode = mode, song = state.song,
           title = state.song and state.song:match("|(.*)$") or "" }
end

-- ── Listener (only runs while the pill is up) ─────────────────────────────────
-- audiotee ignores SIGTERM, and an orphaned copy holds a Core Audio tap open
-- forever; enough of them wedge coreaudiod and break dictation (2026-10-21).
local function killOrphanTaps()
  hs.execute([[/bin/ps -axo pid=,ppid=,comm= | /usr/bin/awk '$2 == 1 && $3 ~ /audiotee$/ {print $1}' | /usr/bin/xargs kill -9 2>/dev/null]])
end

function stopListener()
  local t = activeWatchers.songKeyListen
  if t then
    activeWatchers.songKeyListen = nil
    local pid = t:pid()
    if pid then hs.execute("/usr/bin/pkill -9 -P " .. pid) end
    t:terminate()
  end
  killOrphanTaps()
end

function startListener()
  if activeWatchers.songKeyListen then return end
  killOrphanTaps()
  state.ear, state.earStatus = {}, "listening"
  local partial = ""
  local task
  task = hs.task.new(CFG.LISTEN, function()
    if activeWatchers.songKeyListen == task then
      activeWatchers.songKeyListen = nil
      state.earStatus = "error"
      redraw()
    end
  end, function(_, out)
    partial = partial .. (out or "")
    for line in partial:gmatch("([^\n]*)\n") do
      local ok, r = pcall(hs.json.decode, line)
      if ok and type(r) == "table" then
        if r.silent then state.ear, state.earStatus = {}, "quiet"
        elseif r.error then state.earStatus = "error"
        elseif r.chroma then
          table.insert(state.ear, r)
          while #state.ear > CFG.SMOOTH do table.remove(state.ear, 1) end
          state.earStatus = nil
        end
      end
    end
    partial = partial:match("[^\n]*$")
    redraw()
    refresh()
    return true
  end, CFG.LISTEN_DEVICE and { CFG.LISTEN_DEVICE }
         or state.source and state.source:match("^device:(.+)$") and { state.source:sub(8) }
         or state.source and { "--app", state.source }
         or {})                     -- no args → all system audio
  activeWatchers.songKeyListen = task
  task:start()
end

local function lookup(artist, title, song)
  redraw()
  if activeWatchers.songKeyLookup then activeWatchers.songKeyLookup:terminate() end
  activeWatchers.songKeyLookup = hs.task.new(CFG.LOOKUP, function(code, out)
    activeWatchers.songKeyLookup = nil
    if state.song ~= song then return end          -- the song changed meanwhile
    local ok, r = pcall(hs.json.decode, out or "")
    if code ~= 0 or not ok or type(r) ~= "table" then r = { found = false } end
    state.result = r
    redraw()
    refresh()
  end, { artist, title })
  activeWatchers.songKeyLookup:start()
end

-- Music players checked for a playing track, by bundle ID. Never look apps up by
-- name: hs.application.get("Spotify") with Spotify closed falls back to scanning
-- every window of every app through accessibility (100-250 ms on the main thread,
-- seconds when an app is hung), and every key press waits on Hammerspoon's key taps.
local PLAYERS = { { id = "com.apple.Music", name = "Music" }, { id = "com.spotify.client", name = "Spotify" } }

-- Async, off the main thread: cb(title, artist, bundleID) from the first running
-- player that is playing, else cb(nil). A hung player only delays the next poll.
function M.playerTrack(cb)
  local list = {}
  for _, p in ipairs(PLAYERS) do
    if hs.application.applicationsForBundleID(p.id)[1] then table.insert(list, p) end
  end
  local i = 0
  local function nextPlayer()
    i = i + 1
    if not list[i] then return cb(nil) end
    activeWatchers.songKeyPlayer = hs.task.new("/usr/bin/osascript", function(code, out)
      activeWatchers.songKeyPlayer = nil
      local t, a = (out or ""):match("^(.-)\n(.-)\n?$")
      if code == 0 and t and t ~= "" then cb(t, a, list[i].id) else nextPlayer() end
    end, { "-e", 'tell application "' .. list[i].name .. '" to if player state is playing then return (name of current track) & linefeed & (artist of current track)' })
    activeWatchers.songKeyPlayer:start()
  end
  nextPlayer()
end

local function poll()
  if activeWatchers.songKeyPoll then return end    -- previous check still running
  activeWatchers.songKeyPoll = hs.task.new(CFG.NOWPLAYING, function(_, out)
    local lines = {}
    for line in ((out or "") .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end
    local title, artist, rate = lines[1] or "", lines[2] or "", tonumber(lines[3] or "") or 0
    local bundle = lines[4]
    -- A music player that is actually playing beats the system Now Playing pick
    -- (a paused YouTube tab can keep claiming it).
    M.playerTrack(function(playerTitle, playerArtist, playerBundle)
      activeWatchers.songKeyPoll = nil
      if not activeWatchers.songKeyTimer then return end   -- stopped meanwhile
      if playerTitle then title, artist, rate, bundle = playerTitle, playerArtist, 1, playerBundle end
      local now = hs.timer.secondsSinceEpoch()
      state.playing = rate > 0 and title ~= "" and title ~= "null"
      if state.playing then
        state.lastPlaying = now
        if artist == "null" then artist = "" end
        local song = artist .. "|" .. title
        if song ~= state.song then
          state.song, state.result = song, nil
          state.ear = {}
          if state.earStatus == nil then state.earStatus = "listening" end
          lookup(artist, title, song)
        end
        -- The ear listens only to the app playing the song; switch when that changes.
        local app = bundle and bundle ~= "null" and hs.application.applicationsForBundleID(bundle)[1]
        local source = app and app:path() or nil
        local device = bundle and DEVICE_FOR[bundle]
        if device and hs.audiodevice.findInputByName(device) then source = "device:" .. device end
        if source ~= state.source then
          state.source = source
          stopListener()
        end
        state.bundle = bundle ~= "null" and bundle or nil
        local resting = state.mode == "pill" and state.result and state.result.found
        local skip = state.hiddenFor == song or resting or (state.bundle and IGNORE[state.bundle])
        -- The ear runs while something plays (hidden too), so it can tell music from speech.
        if not skip and not activeWatchers.songKeyListen then startListener() end
        refresh()
      elseif now - state.lastPlaying > CFG.PAUSE_HIDE then
        hide()
        if activeWatchers.songKeyListen then stopListener() end
      end
    end)
  end, { "get", "title", "artist", "playbackRate", "clientBundleIdentifier" })
  activeWatchers.songKeyPoll:start()
end

function M.start()
  M.stop()
  activeWatchers.songKeyTimer = hs.timer.doEvery(CFG.POLL, poll)
  activeWatchers.songKeyScreens = hs.screen.watcher.new(function()
    if activeWatchers.songKeyView and state.mode then activeWatchers.songKeyView:frame(rect()) end
  end):start()
  activeWatchers.songKeyHotkey = hs.hotkey.bind(CFG.HOTKEY[1], CFG.HOTKEY[2], M.toggle)
  -- A palette change in the Tweaks panel re-renders the page in the new colours.
  require("modules.guard_kit").onPaletteChange(function()
    local wv = activeWatchers.songKeyView
    if wv then state.ready = false; wv:html(pageHtml()) end
  end)
  poll()
end

function M.stop()
  stopTimers()
  for _, k in ipairs({ "songKeyTimer", "songKeyScreens", "songKeyMouse" }) do
    if activeWatchers[k] then activeWatchers[k]:stop(); activeWatchers[k] = nil end
  end
  if activeWatchers.songKeyHotkey then activeWatchers.songKeyHotkey:delete(); activeWatchers.songKeyHotkey = nil end
  for _, k in ipairs({ "songKeyPoll", "songKeyPlayer", "songKeyLookup", "songKeyListen" }) do
    if activeWatchers[k] then activeWatchers[k]:terminate(); activeWatchers[k] = nil end
  end
  if activeWatchers.songKeyView then activeWatchers.songKeyView:delete(); activeWatchers.songKeyView = nil end
  state.song, state.result, state.mode, state.ready, state.pending = nil, nil, nil, false, nil
  state.ear, state.earStatus, state.bundle = {}, nil, nil
  state.pinned, state.hiddenFor, state.preview, state.hovering = false, nil, nil, false
end

-- Test hook: shows the card or pill with a sample song, music or not (the live poll pauses).
-- preview("card" | "pill", { dark = true }) · preview(nil) goes back to live.
function M.preview(mode, opts)
  if not mode then
    if activeWatchers.songKeyView then activeWatchers.songKeyView:hide() end
    return M.start()
  end
  if activeWatchers.songKeyTimer then activeWatchers.songKeyTimer:stop(); activeWatchers.songKeyTimer = nil end
  stopListener()
  local r = { found = true, key = "E Major", source = "Hooktheory", url = "https://www.hooktheory.com" }
  local d = M.describe(r, "Alison", { key = "E major", chroma = {}, stable = true, strength = 1 })
  d.ear = "Live agrees ✓ · hearing E major"
  d.pill, d.pillFull, d.dark, d.title = M.shortKey(r.key), r.key, opts and opts.dark or nil, "Alison"
  state.preview, state.song = d, "Elvis Costello|Alison"
  if not state.mode then switchTo("pill") end
  if mode == "card" then M.openCard() elseif state.mode == "card" then collapse() else redraw() end
  return rect(mode)
end

-- Test hook: what it is showing right now.
function M.status()
  local wv = activeWatchers.songKeyView
  return { visible = wv and wv:isVisible() or false, mode = state.mode, song = state.song,
           playing = state.playing, shown = state.pending, result = state.result,
           ear = M.earSummary(state.ear), earStatus = state.earStatus, heard = heardNow(),
           pinned = state.pinned, hiddenFor = state.hiddenFor, bundle = state.bundle,
           listening = activeWatchers.songKeyListen ~= nil,
           frame = wv and wv:frame() or nil }
end

return M
