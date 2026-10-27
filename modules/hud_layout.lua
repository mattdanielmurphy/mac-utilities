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
function M.place(f, slot, w, h)
  w, h = w or slot.w, h or slot.h
  local corner = slot.corner or "bottomRight"
  local x = corner:find("Right") and (f.x + f.w - slot.dx - w) or (f.x + slot.dx)
  local y = corner:find("^bottom") and (f.y + f.h - slot.dy - h) or (f.y + slot.dy)
  return { x = x, y = y, w = w, h = h }
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
          if intersects(here[i].r, here[j].r) then
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
