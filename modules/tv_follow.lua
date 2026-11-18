-- ~/.hammerspoon/modules/tv_follow.lua
-- TV Follow (2026-11-14, edge redesigned 2026-11-15): the Sony TV comes on when you use the
-- Mac, a push of the cursor switches it, and windows follow the TV.
--
--   you use the Mac   first touch after idle.minutes, wake or unlock, and the TV is off →
--                     TV on, Mac's input. A TV that's on, showing anything else (an app,
--                     Settings, another HDMI), is never switched by itself.
--   portal            the TV sits above the laptop. While it isn't showing the Mac, nearing the
--                     top edge shows a faint glow behind the menu bar (the menu bar stays usable,
--                     cursor visible). Push on past the edge and the cursor goes onto the dark TV,
--                     so it disappears, and the glow widens and deepens the further you go, like
--                     entering a portal; pull back and it retreats. Go deep enough and the TV
--                     switches to the Mac, with your cursor already up there. A small slip past
--                     the edge (reaching for the menu bar) snaps back as soon as you move down;
--                     a cursor left up there unmoved comes back by itself; clicks up there are
--                     swallowed. A cursor already on the TV when it stops showing the Mac is
--                     moved down to the laptop. All feel knobs are live (Tweaks → TV Follow).
--   windows away      TV off or on another input (and the laptop screen is open) → windows on
--                     the TV move to the laptop screen; new ones that open there follow
--   windows back      TV shows the Mac again → each moved window returns to its old spot,
--                     unless you've moved it since
--
-- The TV is reached through lidstay's tv.py server (127.0.0.1:47613, LaunchAgent
-- local.lidstay.tv), because macOS Local Network privacy blocks Hammerspoon from the LAN.
-- Without the TV's pre-shared key (BRAVIA_PSK in ~/projects/lidstay/.env) the TV can only be
-- woken (Wake-on-LAN) and its input is unknown; see lidstay's README.
-- The glow fills the menu-bar band (hud_slots.json exempt: tv_follow_portal). Knobs: Tweaks panel (⌃⌥⌘T) → "TV Follow".
-- Tests: lua tests/tv_follow_test.lua

local M = { id = "tv_follow", name = "TV Follow (TV on when you use the Mac, push up through the portal to switch)", defaultEnabled = true }

_G.activeWatchers = _G.activeWatchers or {}
local W = _G.activeWatchers
local T
local SERVER = "http://127.0.0.1:47613"

-- ── Decision logic (pure; tested in tests/tv_follow_test.lua) ──────────────────
-- s: state (mutated). i: { now, idle, tv = {power,input} | nil, builtin, cfg }.
-- Returns a list of actions: "away", "back", "summon:<reason>".
function M.decide(s, i)
  local cfg, out = i.cfg, {}
  local tv = i.tv
  local prevIdle = s.prevIdle or 0
  s.prevIdle = i.idle

  local known = tv and (tv.power == "standby" or (tv.power == "active" and (tv.input == "mac" or tv.input == "other")))
  local showing = known and tv.power == "active" and tv.input == "mac"
  if known then
    if not s.away and not showing and i.builtin and cfg.moveWindows then
      s.away = true; out[#out + 1] = "away"
    elseif s.away and (showing or not i.builtin) then
      s.away = false; out[#out + 1] = "back"
    end
  end

  if prevIdle >= cfg.idleMinutes * 60 and i.idle < 10 then
    if M.offForSummon(tv) then
      M.summon(s, i.now, string.format("back after %d min idle", math.floor(prevIdle / 60)), cfg, out)
    end
  end
  return out
end

-- Only an off (or not answering) TV is switched by itself; one that's on is left alone.
function M.offForSummon(tv) return not tv or tv.power ~= "active" end

-- Portal. e = { depth = points past the laptop's TV-facing edge (> 0: on the TV, ≤ 0: still on
-- the laptop, -depth from the edge), out = this move toward the TV (< 0: pulling back) }.
-- Returns { progress = 0..1 depth into the portal, preview = 0..1 nearness to the edge,
-- action = nil | "snap" (put the cursor back on the laptop) | "summon" (switch now) }.
function M.portal(s, now, e, cfg)
  local r = { progress = 0, preview = 0 }
  if not s.away then return r end
  if s.committed then r.progress = 1; return r end
  if e.depth > 0 then
    s.inPortal, s.lastMove = true, now
    local f = math.min(1, e.depth / cfg.depthPt)
    if e.out < 0 and f < cfg.snapFraction then
      s.inPortal = false; r.action = "snap"; return r
    end
    if f >= 1 then
      local o = {}
      M.summon(s, now, "pushed the cursor up through the portal", cfg, o)
      if o[1] then s.committed = now; r.action = "summon"; r.progress = 1; return r end
      f = 0.999 -- within the cooldown: hold just short of full
    end
    r.progress = f
    return r
  end
  s.inPortal = false
  local gap = -e.depth
  if cfg.previewPt > 0 and gap < cfg.previewPt then r.preview = 1 - gap / cfg.previewPt end
  return r
end

-- True when a cursor left in the portal unmoved should come back to the laptop.
function M.portalIdle(s, now, cfg)
  return s.inPortal and not s.committed and cfg.idleReturnSeconds > 0
    and now - (s.lastMove or now) >= cfg.idleReturnSeconds
end

-- Points past the laptop's TV-facing edge (negative: inside the laptop, that far from it).
function M.depth(p, lap, dir)
  if dir.y < 0 then return lap.y - p.y end
  if dir.y > 0 then return p.y - (lap.y + lap.h) end
  if dir.x < 0 then return lap.x - p.x end
  return p.x - (lap.x + lap.w)
end

-- Unit step from the laptop toward the TV, on the axis they meet along ({0,-1} = TV above).
function M.towards(lap, tv)
  local dx = (tv.x + tv.w / 2) - (lap.x + lap.w / 2)
  local dy = (tv.y + tv.h / 2) - (lap.y + lap.h / 2)
  if math.abs(dy) >= math.abs(dx) then return { x = 0, y = dy < 0 and -1 or 1 } end
  return { x = dx < 0 and -1 or 1, y = 0 }
end

function M.inside(p, f) return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h end

-- Nearest point inside f (1 pt in from its edges).
function M.clampInto(p, f)
  return { x = math.max(f.x + 1, math.min(p.x, f.x + f.w - 2)), y = math.max(f.y + 1, math.min(p.y, f.y + f.h - 2)) }
end

-- Is p on the laptop's edge that faces the TV (within 3 pt)?
function M.atEdge(p, lap, dir)
  if dir.y < 0 then return p.y <= lap.y + 3 end
  if dir.y > 0 then return p.y >= lap.y + lap.h - 4 end
  if dir.x < 0 then return p.x <= lap.x + 3 end
  return p.x >= lap.x + lap.w - 4
end

function M.summon(s, now, reason, cfg, out)
  if now - (s.lastSummon or -math.huge) < cfg.cooldownSeconds then return end
  s.lastSummon = now
  out[#out + 1] = "summon:" .. reason
end

-- Where a window from the TV lands on the laptop: same relative spot, shrunk to fit.
function M.mapFrame(f, from, to)
  local sx, sy = to.w / from.w, to.h / from.h
  local w, h = math.min(f.w, to.w), math.min(f.h, to.h)
  if f.w > to.w or f.h > to.h then w, h = math.min(to.w, f.w * sx), math.min(to.h, f.h * sy) end
  local x = to.x + (f.x - from.x) * sx
  local y = to.y + (f.y - from.y) * sy
  x = math.max(to.x, math.min(x, to.x + to.w - w))
  y = math.max(to.y, math.min(y, to.y + to.h - h))
  return { x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h) }
end

-- ── Mac side ───────────────────────────────────────────────────────────────────

local state, tvState, stash = {}, nil, {}
local FILE = os.getenv("HOME") .. "/.hammerspoon/state/tv_follow.json"

-- Moved windows survive a Hammerspoon reload, so they still come back afterwards.
local function save()
  local list = {}
  for id, e in pairs(stash) do list[#list + 1] = { id = id, tvFrame = e.tvFrame, laptopFrame = e.laptopFrame, pid = e.pid } end
  hs.json.write({ away = state.away or false, windows = list }, FILE, true, true)
end
local function loadStash()
  stash = {}
  local j = hs.fs.attributes(FILE) and hs.json.read(FILE)
  if type(j) ~= "table" then return false end
  for _, e in ipairs(j.windows or {}) do stash[e.id] = { tvFrame = e.tvFrame, laptopFrame = e.laptopFrame, pid = e.pid } end
  return j.away == true
end

local function cfg()
  return {
    idleMinutes = T("idle.minutes"), cooldownSeconds = T("summon.cooldownSeconds"),
    depthPt = T("portal.depthPt"), snapFraction = T("portal.snapFraction"),
    previewPt = T("portal.previewPt"), idleReturnSeconds = T("portal.idleReturnSeconds"),
    moveWindows = T("windows.move"),
  }
end

local function screens()
  local tv, builtin
  local want = (T("display.nameContains") or "TV"):lower()
  for _, sc in ipairs(hs.screen.allScreens()) do
    local name = sc:name() or ""
    if name:find("Built%-in") or name:find("Color LCD") then builtin = sc
    elseif not tv and name:lower():find(want, 1, true) then tv = sc end
  end
  return tv, builtin
end

local function near(a, b) return math.abs(a.x - b.x) < 4 and math.abs(a.y - b.y) < 4 and math.abs(a.w - b.w) < 4 and math.abs(a.h - b.h) < 4 end
local function plain(f) return { x = f.x, y = f.y, w = f.w, h = f.h } end

-- Apps with a window on the TV, from the window server's list (no accessibility, ~1 ms).
-- Why (2026-11-15): the sweep used hs.window.allWindows(), which asks every app through
-- accessibility; run on every 3 s poll while away it froze the keyboard 0.35-1 s each time.
function M.tvPids(list, f)
  local pids = {}
  for _, w in ipairs(list or {}) do
    local b = w.kCGWindowBounds
    if w.kCGWindowLayer == 0 and b and b.Width > 50 and b.Height > 50 and w.kCGWindowOwnerPID then
      local cx, cy = b.X + b.Width / 2, b.Y + b.Height / 2
      if cx >= f.x and cx < f.x + f.w and cy >= f.y and cy < f.y + f.h then pids[w.kCGWindowOwnerPID] = true end
    end
  end
  return pids
end

-- Move every movable window on the TV to the laptop screen (also run each poll while away).
local function sweep(tv, builtin)
  if not (tv and builtin) then return 0 end
  local from, to, n = tv:frame(), builtin:frame(), 0
  local pids = M.tvPids(hs.window.list and hs.window.list(true), tv:fullFrame())
  for pid in pairs(pids) do
    local app = hs.application.applicationForPID(pid)
    for _, win in ipairs(app and app:allWindows() or {}) do
      local id = win:id()
      if id and win:isStandard() and win:isVisible() and not win:isFullScreen() and win:screen() == tv then
        local old = plain(win:frame())
        local new = M.mapFrame(old, from, to)
        win:setFrame(new, 0)
        stash[id] = { tvFrame = old, laptopFrame = plain(win:frame()), pid = pid }
        n = n + 1
      end
    end
  end
  if n > 0 then save() end
  return n
end

-- Put stashed windows back. Looks windows up per app: hs.window.get(id) walks every app's
-- windows through accessibility, and 17 of those took 4.8 s (2026-11-15).
local function restore(tv)
  local n = 0
  if tv then
    local byId, pids, unknown = {}, {}, false
    for _, e in pairs(stash) do if e.pid then pids[e.pid] = true else unknown = true end end
    local function add(wins) for _, w in ipairs(wins or {}) do local id = w:id(); if id then byId[id] = w end end end
    for pid in pairs(pids) do
      local app = hs.application.applicationForPID(pid)
      if app then add(app:allWindows()) end
    end
    if unknown then add(hs.window.allWindows()) end -- stash saved before pids were kept
    for id, e in pairs(stash) do
      local win = byId[tonumber(id) or id]
      if win and near(plain(win:frame()), e.laptopFrame) then win:setFrame(e.tvFrame, 0); n = n + 1 end
    end
  end
  stash = {}
  save()
  return n
end

local function post(path, cb)
  hs.http.asyncPost(SERVER .. path, "", nil, function(code, body)
    local ok, j = pcall(hs.json.decode, body or "")
    if cb then cb(code, ok and j or nil) end
  end)
end

function M.summonNow(reason)
  print("📺 [tv_follow] TV → Mac (" .. reason .. ")")
  post("/mac", function(code)
    if code ~= 200 then print("📺 [tv_follow] tv.py server not answering (" .. tostring(code) .. "); is local.lidstay.tv running?") end
  end)
end

-- ── Portal glow: a band behind the menu bar on the laptop screen ──────────────────
local glow, anim
local shown, target, preview, flashUntil = 0, 0, 0, 0
local geo -- { lap, tv, dir, menuH } full frames, refreshed by apply()

local function accentHex()
  local ok, pal = pcall(require, "modules.slub_palette")
  local seeds = ok and pal.seeds and pal.seeds()
  local role = T("portal.colorRole")
  return seeds and (seeds[role] or seeds.accent) or nil
end

local function glowHide()
  if anim then anim:stop(); anim = nil end
  if glow then glow:delete(); glow = nil end
  shown, target, preview = 0, 0, 0
end

-- Draws the band for the current shown/preview values. Every knob is read here, each frame,
-- so changes in the Tweaks panel show at once.
local function glowDraw()
  if not geo then return end
  local lap = geo.lap
  local ease = shown ^ T("portal.curve")
  local strength = math.max(ease, preview * T("portal.previewStrength"))
  local hex = accentHex()
  if not hex or strength <= 0.003 then if glow then glow:hide() end return end
  local wFrac = T("portal.startWidth") + (1 - T("portal.startWidth")) * ease
  if ease <= 0 then wFrac = T("portal.previewWidth") end
  local h = geo.menuH + T("portal.growPt") * ease
  local frame = { x = lap.x, y = lap.y, w = lap.w, h = math.max(geo.menuH, h) }
  if not glow then
    glow = hs.canvas.new(frame)
    glow:level(T("portal.overMenuBar") and hs.canvas.windowLevels.overlay or (hs.canvas.windowLevels.mainMenu - 1))
    glow:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
    glow:clickActivating(false)
    glow:canvasMouseEvents(false, false, false, false)
  else
    glow:frame(frame)
    glow:level(T("portal.overMenuBar") and hs.canvas.windowLevels.overlay or (hs.canvas.windowLevels.mainMenu - 1))
  end
  local now = hs.timer.secondsSinceEpoch()
  local flash = now < flashUntil and T("portal.flashBoost") or 0
  local a = math.min(1, T("portal.alpha") * strength + flash)
  local edgeA = a * T("portal.edgeAlpha")
  local w = lap.w * wFrac
  local fh = frame.h
  glow:replaceElements({
    type = "rectangle", action = "fill",
    frame = { x = (lap.w - w) / 2, y = 0, w = w, h = fh },
    roundedRectRadii = { xRadius = T("portal.radius"), yRadius = T("portal.radius") },
    fillGradient = "linear", fillGradientAngle = T("portal.gradientAngle"),
    fillGradientColors = {
      { hex = hex, alpha = edgeA }, { hex = hex, alpha = a }, { hex = hex, alpha = edgeA },
    },
  })
  glow:show()
end

-- Eases shown toward target each frame (portal.smoothing), then sleeps once everything is out.
local function glowKick()
  if anim then return end
  anim = hs.timer.doEvery(1 / 60, function()
    local k = T("portal.smoothing")
    shown = shown + (target - shown) * k
    if math.abs(target - shown) < 0.002 then shown = target end
    local now = hs.timer.secondsSinceEpoch()
    if M.portalIdle(state, now, cfg()) and geo then
      state.inPortal = false
      local p = hs.mouse.absolutePosition()
      hs.mouse.absolutePosition(M.clampInto({ x = p.x, y = geo.lap.y + geo.menuH + 4 }, geo.lap))
      target = 0
    end
    if state.committed and now - state.committed > T("portal.commitSeconds") then
      state.committed = nil; target = 0 -- the TV never came over: let go
    end
    glowDraw()
    if shown <= 0.002 and target == 0 and preview <= 0 and now >= flashUntil and not state.inPortal then
      if anim then anim:stop(); anim = nil end
      if glow then glow:hide() end
    end
  end)
end

local function moveOffTV()
  if not geo then return end
  local p = hs.mouse.absolutePosition()
  if M.inside(p, geo.tv) then
    hs.mouse.absolutePosition({ x = geo.lap.x + geo.lap.w / 2, y = geo.lap.y + geo.lap.h / 2 })
    print("📺 [tv_follow] cursor was on the TV: moved it to the laptop screen")
  end
end

local function onMove(ev)
  if not geo then return false end
  local p = ev:location()
  local d = M.depth(p, geo.lap, geo.dir)
  if d <= -math.max(T("portal.previewPt"), 1) and not state.inPortal and shown <= 0 and preview <= 0 then return false end
  local props = hs.eventtap.event.properties
  local out = ev:getProperty(props.mouseEventDeltaX) * geo.dir.x + ev:getProperty(props.mouseEventDeltaY) * geo.dir.y
  local r = M.portal(state, hs.timer.secondsSinceEpoch(), { depth = d, out = out }, cfg())
  target, preview = r.progress, r.preview
  if r.action == "snap" then
    hs.mouse.absolutePosition(M.clampInto({ x = p.x, y = geo.lap.y + 1 }, geo.lap))
  elseif r.action == "summon" then
    flashUntil = hs.timer.secondsSinceEpoch() + T("portal.flashSeconds")
    M.summonNow("pushed the cursor up through the portal")
  end
  glowKick()
  return false
end

-- Clicks on the dark TV (cursor in the portal) would land on invisible things: swallow them.
local function onClick(ev)
  if not (geo and T("portal.swallowClicks")) then return false end
  return M.inside(ev:location(), geo.tv)
end

local function setEdgeWatch(on)
  if on and not W.tvFollowEdge then
    moveOffTV()
    W.tvFollowEdge = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, onMove):start()
    local t = hs.eventtap.event.types
    W.tvFollowClicks = hs.eventtap.new({ t.leftMouseDown, t.rightMouseDown, t.otherMouseDown }, onClick):start()
  elseif not on and W.tvFollowEdge then
    W.tvFollowEdge:stop(); W.tvFollowEdge = nil
    if W.tvFollowClicks then W.tvFollowClicks:stop(); W.tvFollowClicks = nil end
    state.inPortal, state.committed = false, nil
    glowHide()
  end
end

local function apply(actions)
  local tv, builtin = screens()
  geo = (tv and builtin) and { lap = builtin:fullFrame(), tv = tv:fullFrame(),
    dir = M.towards(builtin:fullFrame(), tv:fullFrame()),
    menuH = math.max(builtin:frame().y - builtin:fullFrame().y, T("portal.menuBarFallbackPt")) } or nil
  for _, a in ipairs(actions) do
    if a == "away" then
      save()
      moveOffTV()
      print("📺 [tv_follow] TV not showing the Mac: moved " .. sweep(tv, builtin) .. " windows to the laptop")
    elseif a == "back" then
      print("📺 [tv_follow] TV showing the Mac: put " .. restore(tv) .. " windows back")
    elseif a:sub(1, 7) == "summon:" then
      M.summonNow(a:sub(8))
    end
  end
  if state.away and #actions == 0 and T("windows.move") then sweep(tv, builtin) end -- windows that opened on the TV
  setEdgeWatch(state.away and geo ~= nil and T("edge.on"))
end

local polling = false
local function poll()
  if polling then return end
  polling = true
  hs.http.asyncGet(SERVER .. "/status", nil, function(code, body)
    polling = false
    local ok, j = pcall(hs.json.decode, body or "")
    tvState = (code == 200 and ok and j) or nil
    local tv, builtin = screens()
    if not tv then tvState = nil end -- TV not attached: nothing to follow
    apply(M.decide(state, { now = hs.timer.secondsSinceEpoch(), idle = hs.host.idleTime(),
      tv = tvState, builtin = builtin ~= nil, cfg = cfg() }))
  end)
end

function M.status()
  return { tv = tvState, away = state.away, stashed = (function() local n = 0 for _ in pairs(stash) do n = n + 1 end return n end)() }
end

function M.start()
  M.stop()
  local tweaks = require("modules.tweaks")
  T = T or tweaks.open{
    app = "TV Follow",
    file = tweaks.dir .. "/tv_follow.json",
    knobs = {
      ["timing.pollSeconds"] = { 3, min = 1, max = 15, step = 1, note = "Seconds between TV and idle checks" },
      ["idle.minutes"] = { 10, min = 1, max = 120, step = 1, note = "Idle minutes before your next touch counts as coming back" },
      ["edge.on"] = { true, note = "While the TV isn't showing the Mac, push the cursor up through the portal to switch it" },
      ["portal.depthPt"] = { 220, min = 40, max = 1000, step = 10, note = "How far past the top edge (onto the dark TV) before it switches" },
      ["portal.snapFraction"] = { 0.3, min = 0, max = 1, step = 0.05, note = "Moving down while less than this far in snaps the cursor straight back to the menu bar (0 = never)" },
      ["portal.idleReturnSeconds"] = { 1.2, min = 0, max = 5, step = 0.1, note = "A cursor left in the portal unmoved this long comes back to the laptop (0 = never)" },
      ["portal.previewPt"] = { 6, min = 0, max = 40, step = 1, note = "Within this many points of the top edge, a faint glow hints at the portal (0 = no hint)" },
      ["portal.previewStrength"] = { 0.35, min = 0, max = 1, step = 0.05, note = "How strong that hint gets right at the edge" },
      ["portal.previewWidth"] = { 0.25, min = 0.02, max = 1, step = 0.01, note = "Width of the hint, as a share of the screen" },
      ["portal.startWidth"] = { 0.2, min = 0.02, max = 1, step = 0.01, note = "Width of the glow just past the edge (it widens to full as you go deeper)" },
      ["portal.growPt"] = { 0, min = 0, max = 200, step = 2, note = "Extra height below the menu bar at full depth (0 = stays the menu bar's height)" },
      ["portal.curve"] = { 1.4, min = 0.3, max = 4, step = 0.1, note = "How depth turns into growth: 1 = even, above 1 = slow start then fast" },
      ["portal.smoothing"] = { 0.25, min = 0.03, max = 1, step = 0.01, note = "How quickly the glow follows the cursor each frame (1 = instant)" },
      ["portal.alpha"] = { 0.85, min = 0.05, max = 1, step = 0.05, note = "Glow opacity at its centre at full depth" },
      ["portal.edgeAlpha"] = { 0.15, min = 0, max = 1, step = 0.05, note = "Glow opacity at its ends, as a share of the centre (the gradient)" },
      ["portal.gradientAngle"] = { 0, min = 0, max = 180, step = 5, note = "Gradient direction: 0 = across, 90 = top to bottom" },
      ["portal.radius"] = { 0, min = 0, max = 40, step = 1, note = "Corner rounding of the glow" },
      ["portal.colorRole"] = { "accent", note = "Palette colour for the glow", choices = { accent = "Accent", neutral = "Neutral", success = "Success", warning = "Warning" } },
      ["portal.overMenuBar"] = { false, note = "Draw over the menu bar instead of behind it (behind keeps the menu readable)" },
      ["portal.flashSeconds"] = { 0.6, min = 0, max = 3, step = 0.1, note = "How long it brightens when the TV switches" },
      ["portal.flashBoost"] = { 0.3, min = 0, max = 1, step = 0.05, note = "How much brighter that flash is" },
      ["portal.commitSeconds"] = { 12, min = 3, max = 30, step = 1, note = "If the TV hasn't switched this long after you went through, let go" },
      ["portal.swallowClicks"] = { true, note = "Ignore clicks while the cursor is up on the dark TV" },
      ["portal.menuBarFallbackPt"] = { 24, min = 0, max = 60, step = 1, note = "Band height when the menu bar is hidden" },
      ["summon.cooldownSeconds"] = { 8, min = 2, max = 60, step = 1, note = "Least seconds between two TV → Mac switches" },
      ["summon.onWake"] = { true, note = "Mac wakes or screen unlocks → an off TV turns on, Mac's input (a TV that's on is left alone)" },
      ["windows.move"] = { true, note = "Move windows off the TV while it's off or on another input, and back after" },
      ["display.nameContains"] = { "TV", note = "Part of the TV screen's name" },
    },
  }
  state = { prevIdle = hs.host.idleTime() }
  state.away = loadStash()
  W.tvFollowPoll = hs.timer.doEvery(T("timing.pollSeconds"), poll)
  W.tvFollowWake = hs.caffeinate.watcher.new(function(ev)
    local w = hs.caffeinate.watcher
    if (ev == w.systemDidWake or ev == w.screensDidUnlock) and T("summon.onWake") then
      -- Same rule as coming back from idle: only an off TV is touched.
      if not M.offForSummon(tvState) then return end
      local out = {}
      M.summon(state, hs.timer.secondsSinceEpoch(), ev == w.systemDidWake and "Mac woke" or "screen unlocked", cfg(), out)
      if out[1] then W.tvFollowWakeDelay = hs.timer.doAfter(2, function() M.summonNow(out[1]:sub(8)) end) end
    end
  end):start()
  poll()
end

function M.stop()
  for _, k in ipairs({ "tvFollowPoll", "tvFollowWake", "tvFollowWakeDelay", "tvFollowEdge", "tvFollowClicks" }) do
    if W[k] then W[k]:stop(); W[k] = nil end
  end
  glowHide()
  -- Reloads keep windows where they are; a fresh start sees the TV state and decides again.
end

return M
