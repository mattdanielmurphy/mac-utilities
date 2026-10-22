-- ~/.hammerspoon/modules/song_key.lua
-- Song key HUD (step 1 of the live key detector: web lookup only, no audio analysis).
--
--   • Every POLL seconds asks nowplaying-cli what's playing (Apple Music, Spotify,
--     browsers… anything that shows in the Now Playing widget), whatever the output
--     device and whether or not Ableton is open.
--   • On a new song, runs bin/song-key, which looks the key up on Hooktheory
--     (human transcriptions, with modes per section) and falls back to AcousticBrainz.
--   • Shows a small pill on the built-in display, just left of the Piano HUD's spot,
--     while music plays: the key, the section keys if they differ, and how sure it is.
--     It fades out PAUSE_HIDE seconds after playback stops. Click it to open the
--     Hooktheory page when there is one.

local M = {
  id = "song_key",
  name = "Song Key HUD"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers
local layout = require("modules.hud_layout")

local CFG = {
  POLL       = 4,      -- seconds between now-playing checks
  PAUSE_HIDE = 20,     -- seconds after playback stops before the pill fades
  FADE       = 0.4,
  WIDTH      = 240,
  HEIGHT     = 144,
  NOWPLAYING = "/usr/local/bin/nowplaying-cli",
  LOOKUP     = os.getenv("HOME") .. "/.hammerspoon/bin/song-key",
  LISTEN     = os.getenv("HOME") .. "/.hammerspoon/bin/song-key-listen",
  LISTEN_DEVICE = nil,   -- nil = all system audio (audiotee); or an input device name
  SMOOTH     = 3,      -- listener readings averaged for the ear check
}
M.config = CFG

local state = {
  song = nil,        -- "artist|title" currently shown or being looked up
  result = nil,      -- last song-key JSON
  playing = false,
  lastPlaying = 0,
  visible = false,
  ready = false,
  pending = nil,     -- data waiting for the page to load
  ear = {},          -- recent listener readings (newest last)
  source = nil,      -- path of the app the ear listens to (nil = all system audio)
  earStatus = nil,   -- "listening" | "quiet" | "error" while there is no usable reading
}

local HTML = [==[
<!doctype html><html><head><meta charset="utf-8"><style>
  html, body { margin: 0; height: 100%; background: transparent; overflow: hidden;
    font-family: -apple-system, "SF Pro Display", sans-serif; -webkit-user-select: none; }
  .pill { position: absolute; inset: 0; border-radius: 14px; cursor: pointer;
    background: rgba(20, 24, 28, 0.55); color: #f4f1ea; }
  .label { position: absolute; left: 16px; top: 10px; right: 16px; font-size: 10px;
    letter-spacing: 0.08em; color: rgba(244, 241, 234, 0.6); white-space: nowrap;
    overflow: hidden; text-overflow: ellipsis; }
  .key { position: absolute; left: 16px; top: 24px; right: 16px; font-size: 24px;
    font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sub { position: absolute; left: 16px; top: 54px; right: 16px; font-size: 11px;
    color: rgba(244, 241, 234, 0.6); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .low .key, .low #kb { opacity: 0.7; }
  .ear { position: absolute; left: 16px; top: 120px; right: 16px; font-size: 11px;
    color: rgba(244, 241, 234, 0.75); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  #kb { position: absolute; left: 16px; right: 16px; top: 76px; height: 38px; }
  #kb .w { fill: #f4f1ea; stroke: rgba(20, 24, 28, 0.6); stroke-width: 1; }
  #kb .b { fill: #1c2024; }
  #kb .in.w { fill: #a9d8c3; }  #kb .in.b { fill: #4f9c80; }
  #kb .tonic.w { fill: #e07a5f; } #kb .tonic.b { fill: #c4573d; }
</style></head><body>
<div class="pill" id="pill">
  <div class="label" id="label">SONG KEY</div>
  <div class="key" id="key">…</div>
  <div class="sub" id="sub">&nbsp;</div>
  <svg id="kb" viewBox="0 0 208 38" preserveAspectRatio="none"></svg>
  <div class="ear" id="ear">&nbsp;</div>
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
  // Two octaves, C to B, scale notes shaded and the home note in terracotta.
  function drawKeys(k, alt) {
    var p = parseKey(k), inScale = {}, svg = '', W = 208 / 14;
    if (p) (p.steps || [0]).forEach(function (s) { inScale[(p.tonic + s) % 12] = true; });
    var whites = [0,2,4,5,7,9,11], blacks = { 1:1, 3:2, 6:4, 8:5, 10:6 };
    var altTonic = alt == null ? -1 : alt;
    function cls(pc, c) { return c + (p && (pc === p.tonic || pc === altTonic) ? ' tonic' : inScale[pc] ? ' in' : ''); }
    for (var o = 0; o < 2; o++) whites.forEach(function (pc, i) {
      svg += '<rect class="' + cls(pc, 'w') + '" x="' + ((o * 7 + i) * W) + '" y="0" width="' + W + '" height="38" rx="2"/>';
    });
    for (var o2 = 0; o2 < 2; o2++) for (var pc in blacks) {
      svg += '<rect class="' + cls(+pc, 'b') + '" x="' + ((o2 * 7 + blacks[pc]) * W - W * 0.3) + '" y="0" width="' + (W * 0.6) + '" height="23" rx="1.5"/>';
    }
    document.getElementById('kb').innerHTML = svg;
  }
  document.getElementById('pill').addEventListener('mousedown', function () {
    try { webkit.messageHandlers.songKey.postMessage({ type: 'click' }); } catch (e) {}
  });
  function update(d) {
    document.getElementById('label').textContent = d.label || 'SONG KEY';
    document.getElementById('key').textContent = d.key || '…';
    document.getElementById('sub').textContent = d.sub || ' ';
    document.getElementById('ear').textContent = d.ear || ' ';
    document.getElementById('pill').className = 'pill' + (d.low ? ' low' : '');
    drawKeys(d.kb || d.key, d.altTonic);
  }
</script></body></html>
]==]

-- Reserved slot in hud_slots.json (left of the Piano HUD), so no other HUD lands on it.
local function rect()
  return layout.rect("song_key", CFG.WIDTH, CFG.HEIGHT)
end

local startListener, stopListener   -- defined with the listener below

local function draw(d)
  state.pending = d
  local wv = activeWatchers.songKeyView
  if wv and state.ready then wv:evaluateJavaScript("update(" .. hs.json.encode(d) .. ")") end
end

local function onMessage(msg)
  local body = msg and msg.body or {}
  if body.type == "click" and state.result and state.result.url then
    hs.urlevent.openURL(state.result.url)
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
    :html(HTML)
  activeWatchers.songKeyView = wv
  return wv
end

local function show()
  if state.visible then return end
  local wv = ensureView()
  wv:frame(rect())
  wv:show(CFG.FADE)
  state.visible = true
  startListener()
end

local function hide()
  if not state.visible then return end
  if activeWatchers.songKeyView then activeWatchers.songKeyView:hide(CFG.FADE) end
  state.visible = false
  stopListener()
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
  local d = { label = label, key = r.key, sub = sub, ear = earLine, low = r.confidence == "low" }
  if r.source ~= "Hooktheory" then
    -- Computer analysis often mixes up a key and its relative (same notes), so
    -- show both and draw both home notes; Matt picks by ear.
    local key, kb, alt = M.relativePair(r.key)
    if key then d.key, d.kb, d.altTonic = key, kb, alt end
  end
  return d
end

local function redraw()
  local title = state.song and state.song:match("|(.*)$") or ""
  local ear = state.earStatus == nil and M.earSummary(state.ear) or nil
  draw(M.describe(state.result, title, ear, state.earStatus))
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
    return true
  end, CFG.LISTEN_DEVICE and { CFG.LISTEN_DEVICE }
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
        if source ~= state.source then
          state.source = source
          stopListener()
        end
        show()
        if not activeWatchers.songKeyListen then startListener() end   -- retry after a capture error
      elseif state.visible and now - state.lastPlaying > CFG.PAUSE_HIDE then
        hide()
      end
    end)
  end, { "get", "title", "artist", "playbackRate", "clientBundleIdentifier" })
  activeWatchers.songKeyPoll:start()
end

function M.start()
  M.stop()
  activeWatchers.songKeyTimer = hs.timer.doEvery(CFG.POLL, poll)
  activeWatchers.songKeyScreens = hs.screen.watcher.new(function()
    if activeWatchers.songKeyView then activeWatchers.songKeyView:frame(rect()) end
  end):start()
  poll()
end

function M.stop()
  for _, k in ipairs({ "songKeyTimer", "songKeyScreens" }) do
    if activeWatchers[k] then activeWatchers[k]:stop(); activeWatchers[k] = nil end
  end
  for _, k in ipairs({ "songKeyPoll", "songKeyPlayer", "songKeyLookup", "songKeyListen" }) do
    if activeWatchers[k] then activeWatchers[k]:terminate(); activeWatchers[k] = nil end
  end
  if activeWatchers.songKeyView then activeWatchers.songKeyView:delete(); activeWatchers.songKeyView = nil end
  state.song, state.result, state.visible, state.ready, state.pending = nil, nil, false, false, nil
  state.ear, state.earStatus = {}, nil
end

-- Test hook: what the pill is showing right now.
function M.status()
  local wv = activeWatchers.songKeyView
  return { visible = wv and wv:isVisible() or false, song = state.song,
           playing = state.playing, shown = state.pending, result = state.result,
           ear = M.earSummary(state.ear), earStatus = state.earStatus,
           listening = activeWatchers.songKeyListen ~= nil }
end

return M
