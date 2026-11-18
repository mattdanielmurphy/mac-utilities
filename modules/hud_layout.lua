-- HUD layout: spatial "air traffic control" for on-screen HUDs.
-- Every HUD has a reserved slot in ~/.hammerspoon/hud_slots.json. A HUD asks for its
-- rect here instead of doing its own corner maths, so no two HUDs can land on each
-- other and one HUD growing never moves another (it only grows inside its own slot).
-- Not a module_manager module: HUD modules require it as a library.
--
--   local layout = require("modules.hud_layout")
--   wv:frame(layout.rect("song_key"))            -- slot size
--   wv:frame(layout.rect("piano_hud", w, h))     -- actual size, anchored at the slot's corner
--   layout.report()                              -- overlap check, as text

-- Feel knobs (⌃⌥⌘T Tweaks panel); found by bin/tweaks scan, kept by prune.
local TWEAKS = {
  ["layout.fallbackDx"] = { 24, min = 0, max = 100, step = 2, note = "Pixels from the screen edge for HUDs with no reserved slot" },
  ["layout.fallbackDy"] = { 24, min = 0, max = 100, step = 2, note = "Pixels from the screen bottom for HUDs with no reserved slot" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Hud layout",
  file = require("modules.tweaks").dir .. "/hud_layout.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {}

M.FILE = os.getenv("HOME") .. "/.hammerspoon/hud_slots.json"

-- Screen setups the overlap check tries. Roles say which slots land on which screen.
M.SCENARIOS = {
  { name = "laptop only", screens = {
      { name = "built-in", w = 1496, h = 939, roles = { builtin = true, primary = true, cursor = true } } } },
  { name = "laptop + TV", screens = {
      { name = "built-in", w = 1496, h = 939, roles = { builtin = true, cursor = true } },
      { name = "TV", w = 1920, h = 1080, roles = { primary = true, cursor = true } } } },
}

-- ── Pure functions (no hs.*), tested by tests/hud_layout_test.lua ─────────────

-- Rect of size w×h anchored at the slot's corner inside screen frame f {x,y,w,h}.
-- fullWidth slots (the bottom bar) span the whole screen, whatever w says; centerX slots sit mid-screen.
function M.place(f, slot, w, h)
  w, h = w or slot.w, h or slot.h
  if slot.fullWidth then w = f.w - 2 * (slot.dx or 0) end
  local corner = slot.corner or "bottomRight"
  local x = corner:find("Right") and (f.x + f.w - slot.dx - w) or (f.x + slot.dx)
  if corner:find("Center$") then x = f.x + f.w / 2 - w / 2 + (slot.dx or 0) end  -- bottomCenter / topCenter
  if slot.centerX then x = f.x + (f.w - w) / 2 end
  local y = corner:find("^bottom") and (f.y + f.h - slot.dy - h) or (f.y + slot.dy)
  return { x = x, y = y, w = w, h = h }
end

-- Usable area (rule "Slub utilities respect each other", 2026-11-14): screen frame f minus the
-- bands other utilities hold along its bottom edge (rects {x,y,w,h}, e.g. the bottom bar).
-- A band counts when it touches f's bottom edge and overlaps it sideways.
function M.trimBottom(f, bands)
  local bottom = f.y + f.h
  for _, r in ipairs(bands or {}) do
    if r and r.y + r.h >= bottom - 1 and r.y < bottom and r.x < f.x + f.w and r.x + r.w > f.x then
      bottom = math.max(f.y, math.min(bottom, r.y))
    end
  end
  return { x = f.x, y = f.y, w = f.w, h = bottom - f.y }
end

local function intersects(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- List of problems ("a overlaps b on built-in (laptop only)", "x is off-screen ..."), empty if clean.
function M.check(slots, scenarios)
  local problems, ids = {}, {}
  for id in pairs(slots) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, sc in ipairs(scenarios or M.SCENARIOS) do
    for _, scr in ipairs(sc.screens) do
      local f = { x = 0, y = 0, w = scr.w, h = scr.h }
      local here = {}
      for _, id in ipairs(ids) do
        if scr.roles[slots[id].screen or "builtin"] then
          local r = M.place(f, slots[id])
          here[#here + 1] = { id = id, r = r }
          if r.x < 0 or r.y < 0 or r.x + r.w > f.w or r.y + r.h > f.h then
            problems[#problems + 1] = string.format("%s is off-screen on %s (%s)", id, scr.name, sc.name)
          end
        end
      end
      for i = 1, #here do
        for j = i + 1, #here do
          -- yieldsTo: a HUD that never shows while that one is up (the Song Key pill moves into the bar)
          local a, b = slots[here[i].id], slots[here[j].id]
          -- inside: a HUD drawn inside its host on purpose (the eye break strip in the bottom bar)
          local yields = a.yieldsTo == here[j].id or b.yieldsTo == here[i].id
            or a.inside == here[j].id or b.inside == here[i].id
          -- over: a HUD that may cover these on purpose while it is up (the open-question bubble over
          -- short-lived toasts; the summoned Trackpad Mixer over the bottom bar)
          local function lists(t, id) for _, v in ipairs(t or {}) do if v == id then return true end end return false end
          yields = yields or lists(a.over, here[j].id) or lists(b.over, here[i].id)
          if not yields and intersects(here[i].r, here[j].r) then
            problems[#problems + 1] = string.format("%s overlaps %s on %s (%s)",
              here[i].id, here[j].id, scr.name, sc.name)
          end
        end
      end
    end
  end
  return problems
end

-- ── Live use (hs.*) ───────────────────────────────────────────────────────────

local cache, cacheMtime

-- Slot table, re-read whenever the JSON changes (editing it needs no reload).
function M.slots()
  local attrs = hs.fs.attributes(M.FILE)
  local mtime = attrs and attrs.modification
  if cache and mtime == cacheMtime then return cache end
  local data = mtime and hs.json.read(M.FILE)
  if not (data and data.slots) then
    print("⚠️ hud_layout: can't read " .. M.FILE)
    return cache or {}
  end
  cache, cacheMtime = data.slots, mtime
  return cache
end

function M.slot(id) return M.slots()[id] end

-- Laptop screen first (then Sidecar/iPad), so HUDs stay on the screen in front of Matt.
local function builtinScreen()
  local screens = hs.screen.allScreens()
  for _, want in ipairs({ "built%-in", "sidecar", "ipad" }) do
    for _, s in ipairs(screens) do
      if (s:name() or ""):lower():find(want) then return s end
    end
  end
  return hs.screen.primaryScreen()
end

function M.screen(id)
  local role = (M.slot(id) or {}).screen or "builtin"
  if role == "primary" then return hs.screen.primaryScreen() end
  if role == "cursor" then return hs.mouse.getCurrentScreen() or hs.screen.mainScreen() end
  return builtinScreen()
end

-- Reserved areas: a utility that holds screen space registers fn(screen) → rect or nil (nil
-- while it isn't holding any), and every panel/window placer asks M.usableFrame(screen)
-- instead of screen:frame(). Register in start(), M.reserve(id, nil) in stop().
local reserved = {}
function M.reserve(id, fn) reserved[id] = fn end

function M.usableFrame(scr)
  scr = scr or hs.screen.mainScreen()
  local bands = {}
  for id, fn in pairs(reserved) do
    local ok, r = pcall(fn, scr)
    if ok and r then bands[#bands + 1] = r
    elseif not ok then print("⚠️ hud_layout: reserve " .. id .. ": " .. tostring(r)) end
  end
  local r = M.trimBottom(scr:frame(), bands)
  return hs.geometry.rect(r.x, r.y, r.w, r.h)
end

-- hs.geometry rect for the HUD `id`, sized w×h (default: the whole slot).
function M.rect(id, w, h)
  local slot = M.slot(id)
  if not slot then
    print("⚠️ hud_layout: no slot for " .. tostring(id))
    slot = { corner = "bottomRight", dx = T("layout.fallbackDx"), dy = T("layout.fallbackDy"), w = w or 200, h = h or 100 }
  end
  local r = M.place(M.screen(id):frame(), slot, w, h)
  return hs.geometry.rect(r.x, r.y, r.w, r.h)
end

function M.report()
  local problems = M.check(M.slots())
  if #problems == 0 then return "HUD slots: no overlaps" end
  return "HUD slots:\n- " .. table.concat(problems, "\n- ")
end

return M
