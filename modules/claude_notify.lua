-- ~/.hammerspoon/modules/claude_notify.lua
-- Quiet "Claude finished" toasts, in place of macOS notifications.
--
-- Anything that wants to tell Matt something drops a small file into the inbox:
--   <inbox>/<anything>.json   {"title","body","kind","url","sound"}
--   <inbox>/<anything>.txt    first line = title, rest = body
-- <inbox> is ~/projects/ai-os/tmp/notify on Matt's Mac, else ~/Library/Application Support/MDMA/notify.
-- Write to a dotfile first and rename it in, so a half-written file is never read.
-- Cloud threads write there through the folder tools; local scripts use
-- ~/.hammerspoon/bin/claude-notify. From Lua: claudeNotify.show{ title = "…" }.
--
-- kind sets the tint, like Claude's own banners: "needs" amber (wants Matt), "done" green,
-- "info" blue, "error" red.
-- Each toast keeps its slot (top-right, stacked down) until it goes; others never
-- move. Hovering shows Open / Snooze 10m / Dismiss and pauses the countdown; a
-- plain click dismisses (and opens `url` if given). Toasts only count down while
-- Matt is actually at the Mac, so nothing expires while he's away.

local M = {
  id = "claude_notify",
  name = "Claude Notification Toasts"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

require("hs.canvas")

-- Matt's Mac keeps the inbox in ai-os (cloud threads write there); any other Mac uses
-- MDMA's own folder. bin/claude-notify picks the same one.
local AIOS = os.getenv("HOME") .. "/projects/ai-os"
local INBOX = hs.fs.attributes(AIOS, "mode") == "directory" and (AIOS .. "/tmp/notify")
  or (os.getenv("HOME") .. "/Library/Application Support/MDMA/notify")
local SHOWN = INBOX .. "/shown"
local VISIBLE_SECONDS = 20      -- seconds of Matt being active before a toast fades
local IDLE_AFTER = 30           -- no input for this long = "away", countdown pauses
local MAX_SLOTS = 6
local SLOT_H, CHIP_H = 92, 80
local MIN_W, MAX_W = 340, 620
local layout = require("modules.hud_layout")
local VERSION = "8"
local SNOOZE_SECONDS = 600
local DEFAULT_SOUND = "Tink"

local slots = {}   -- slot index -> toast { canvas, left }
local queue = {}

-- Same look as Claude's own banners: tinted fill, border in a deeper shade of the
-- same hue, dark same-hue text. The tint is the priority.
--   needs = amber (wants Matt), done = green, info = blue, error = red
local TINTS = {
  light = {
    needs = { bg = "#FAD79B", rim = "#EBA337", text = "#6B3A06" },
    done  = { bg = "#CFEBD3", rim = "#5DB36F", text = "#1E4D2B" },
    info  = { bg = "#D3E3F8", rim = "#5B93D6", text = "#1B3F6B" },
    error = { bg = "#F7CFCB", rim = "#D9625A", text = "#6B1D17" },
  },
  dark = {
    needs = { bg = "#4A3511", rim = "#B07A1E", text = "#F5D9A0" },
    done  = { bg = "#1F3A27", rim = "#3E8B55", text = "#BFE6C8" },
    info  = { bg = "#1E3350", rim = "#3F6FA8", text = "#C3D9F3" },
    error = { bg = "#4A2220", rim = "#A8483F", text = "#F5C4BF" },
  },
}

local function palette(kind)
  local set = TINTS[hs.host.interfaceStyle() == "Dark" and "dark" or "light"]
  local t = set[kind] or set.done
  return { bg = { hex = t.bg, alpha = 1 }, rim = { hex = t.rim, alpha = 1 },
           title = { hex = t.text }, body = { hex = t.text }, pill = { hex = t.rim, alpha = 0.30 },
           text = { hex = t.text } }
end

local function freeSlot()
  for i = 1, MAX_SLOTS do
    if not slots[i] then return i end
  end
end

local showNext

local function dismiss(i, openUrl)
  local t = slots[i]
  if not t then return end
  slots[i] = nil
  if openUrl and t.url then require("modules.claude_links").open(t.url) end
  t.canvas:delete(0.25)
  if #queue > 0 then hs.timer.doAfter(0.3, showNext) end
end

local function icon(kind, col)
  local st = { strokeColor = col, strokeWidth = 2, strokeCapStyle = "round", strokeJoinStyle = "round" }
  local function el(t) for k, v in pairs(st) do t[k] = v end return t end
  if kind == "needs" then      -- warning triangle
    return {
      el{ type = "segments", action = "stroke", closed = true, fillColor = { alpha = 0 },
          coordinates = { { x = 24, y = 17 }, { x = 35, y = 37 }, { x = 13, y = 37 } } },
      el{ type = "segments", action = "stroke", coordinates = { { x = 24, y = 24 }, { x = 24, y = 30 } } },
      el{ type = "segments", action = "stroke", coordinates = { { x = 24, y = 33.5 }, { x = 24, y = 33.6 } } },
    }
  end
  local ring = el{ type = "circle", action = "stroke", center = { x = 24, y = 27 }, radius = 11 }
  if kind == "done" then
    return { ring, el{ type = "segments", action = "stroke",
      coordinates = { { x = 19, y = 27 }, { x = 23, y = 31 }, { x = 30, y = 23 } } } }
  elseif kind == "error" then
    return { ring,
      el{ type = "segments", action = "stroke", coordinates = { { x = 24, y = 21 }, { x = 24, y = 28 } } },
      el{ type = "segments", action = "stroke", coordinates = { { x = 24, y = 32 }, { x = 24, y = 32.1 } } } }
  end
  return { ring,   -- info
    el{ type = "segments", action = "stroke", coordinates = { { x = 24, y = 26 }, { x = 24, y = 33 } } },
    el{ type = "segments", action = "stroke", coordinates = { { x = 24, y = 21.5 }, { x = 24, y = 21.6 } } } }
end

local function draw(i, msg)
  local kind = TINTS.light[msg.kind] and msg.kind or "done"
  local p = palette(kind)
  local title = tostring(msg.title or "Claude finished")
  local body = msg.body and tostring(msg.body) or nil
  local clip = { lineBreak = "truncateTail" }
  local titleStyle = { font = { name = ".AppleSystemUIFontDemi", size = 19 }, color = p.title, paragraphStyle = clip }
  local bodyStyle = { font = { name = ".AppleSystemUIFont", size = 15 }, color = p.body, paragraphStyle = clip }

  -- Width hugs the text; the chip is right-anchored so it only grows leftward.
  local tw = hs.drawing.getTextDrawingSize(title, titleStyle).w
  local bw = body and hs.drawing.getTextDrawingSize(body, bodyStyle).w or 0
  local w = math.floor(math.max(MIN_W, math.min(MAX_W, math.max(tw, bw) + 112)))
  local h = body and CHIP_H or 54

  -- First chip sits at the top of the "claude_notify" HUD slot (below the control pill).
  local r = layout.rect("claude_notify", w, h)
  local frame = { x = r.x, y = r.y + (i - 1) * SLOT_H, w = w, h = h }
  local c = hs.canvas.new(frame)
  c:level(hs.canvas.windowLevels.screenSaver)
  c:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  c:appendElements(
    -- Inset by half the stroke so the canvas edge doesn't clip it (clipped strokes
    -- look thick at the corners).
    { type = "rectangle", action = "strokeAndFill", roundedRectRadii = { xRadius = 16, yRadius = 16 },
      frame = { x = 0.5, y = 0.5, w = w - 1, h = h - 1 },
      fillColor = p.bg, strokeColor = p.rim, strokeWidth = 1.5 }
  )
  for _, e in ipairs(icon(kind, p.text)) do c:appendElements(e) end
  c:appendElements(
    { type = "text", text = hs.styledtext.new(title, titleStyle),
      frame = { x = 56, y = body and 16 or 14, w = w - 112, h = 26 } }
  )
  local textIdx = { #c }
  if body then
    c:appendElements({ type = "text", text = hs.styledtext.new(body, bodyStyle),
      frame = { x = 56, y = 44, w = w - 112, h = 22 } })
    textIdx[2] = #c
  end

  -- Close X, always visible like Claude's banner.
  local cx, cy = w - 28, body and 29 or h / 2
  c:appendElements(
    { id = "dismiss", type = "rectangle", action = "fill", frame = { x = cx - 14, y = cy - 14, w = 28, h = 28 },
      fillColor = { alpha = 0.001 }, trackMouseUp = true },
    { type = "segments", action = "stroke", strokeColor = p.text, strokeWidth = 2, strokeCapStyle = "round",
      coordinates = { { x = cx - 6, y = cy - 6 }, { x = cx + 6, y = cy + 6 } } },
    { type = "segments", action = "stroke", strokeColor = p.text, strokeWidth = 2, strokeCapStyle = "round",
      coordinates = { { x = cx + 6, y = cy - 6 }, { x = cx - 6, y = cy + 6 } } }
  )

  -- Hover actions: pills left of the X, hidden until the pointer is over the toast.
  -- The toast never changes size; the text just truncates a little earlier.
  local actions = {}
  if msg.url then actions[#actions + 1] = { id = "open", label = "Open" } end
  actions[#actions + 1] = { id = "snooze", label = "Snooze 10m" }
  local pillStyle = { font = { name = ".AppleSystemUIFontMedium", size = 13 }, color = p.text,
                      paragraphStyle = { alignment = "center" } }
  local PILL_H, PILL_GAP, PILL_PAD = 28, 6, 12
  local x = cx - 14 - 8
  local pillIdx = {}
  for k = #actions, 1, -1 do
    local a = actions[k]
    local pw = math.ceil(hs.drawing.getTextDrawingSize(a.label, pillStyle).w) + PILL_PAD * 2
    x = x - pw
    local y = math.floor(cy - PILL_H / 2)
    c:appendElements(
      { id = a.id, type = "rectangle", action = "skip", roundedRectRadii = { xRadius = 8, yRadius = 8 },
        frame = { x = x, y = y, w = pw, h = PILL_H }, fillColor = p.pill, strokeColor = p.rim,
        strokeWidth = 1, trackMouseUp = true },
      { type = "text", action = "skip", text = hs.styledtext.new(a.label, pillStyle),
        frame = { x = x, y = y + 5, w = pw, h = PILL_H - 6 } }
    )
    pillIdx[#pillIdx + 1] = #c - 1
    pillIdx[#pillIdx + 1] = #c
    x = x - PILL_GAP
  end
  local hoverTextW = math.max(60, x - 56 - 4)

  local function setHover(on)
    local t = slots[i]
    if t then t.hover = on end
    for _, idx in ipairs(pillIdx) do
      c[idx].action = on and (c[idx].type == "text" and "fill" or "strokeAndFill") or "skip"
    end
    for _, idx in ipairs(textIdx) do
      c[idx].frame = { x = 56, y = c[idx].frame.y, w = on and hoverTextW or (w - 112), h = c[idx].frame.h }
    end
  end

  c:canvasMouseEvents(false, true, true, false)
  c:mouseCallback(function(_, message, id)
    if message == "mouseEnter" then setHover(true)
    elseif message == "mouseExit" then setHover(false)
    elseif message == "mouseUp" then
      if id == "open" then dismiss(i, true)
      elseif id == "snooze" then
        dismiss(i, false)
        local again = {}
        for key, v in pairs(msg) do again[key] = v end
        activeWatchers["claudeNotifySnooze" .. tostring(again)] = hs.timer.doAfter(SNOOZE_SECONDS, function()
          M.show(again)
        end)
      elseif id == "dismiss" then dismiss(i, false)
      else dismiss(i, true) end   -- click anywhere else: open (if url) and dismiss
    end
  end)
  c:alpha(1)
  c:show()

  slots[i] = { canvas = c, url = msg.url, left = tonumber(msg.seconds) or VISIBLE_SECONDS }

  local sound = msg.sound
  if sound == nil then sound = DEFAULT_SOUND end
  if sound and sound ~= false and sound ~= "" then
    local snd = hs.sound.getByName(tostring(sound))
    if snd then snd:volume(0.35):play() end
  end
end

showNext = function()
  while #queue > 0 do
    local i = freeSlot()
    if not i then return end
    local msg = table.remove(queue, 1)
    local ok, err = pcall(draw, i, msg)
    if not ok then print("claude_notify: " .. tostring(err)) end
  end
end

function M.show(msg)
  if type(msg) == "string" then msg = { title = msg } end
  queue[#queue + 1] = msg or {}
  -- Draw on a timer so an `hs -c` caller returns at once (see claude_control).
  activeWatchers.claudeNotifyDraw = hs.timer.doAfter(0, showNext)
  return "queued"
end

-- ── Inbox ───────────────────────────────────────────────────────────────────────

local function parse(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  if path:sub(-5) == ".json" then
    local ok, data = pcall(hs.json.decode, raw)
    if ok and type(data) == "table" then return data end
    return nil
  end
  local title, body = raw:match("^([^\n]*)\n?(.*)$")
  body = body and body:gsub("%s+$", "") or ""
  return { title = title, body = body ~= "" and body or nil }
end

local function scanInbox()
  local names = {}
  for name in hs.fs.dir(INBOX) do
    if name:sub(1, 1) ~= "." and (name:sub(-5) == ".json" or name:sub(-4) == ".txt") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local path = INBOX .. "/" .. name
    local msg = parse(path)
    os.rename(path, SHOWN .. "/" .. name)
    if msg then M.show(msg) else print("claude_notify: couldn't read " .. name) end
  end
end

-- Countdown runs only while Matt is at the keyboard/mouse.
local function tick()
  if hs.host.idleTime() >= IDLE_AFTER then return end
  for i = 1, MAX_SLOTS do
    local t = slots[i]
    if t and not t.hover then
      t.left = t.left - 1
      if t.left <= 0 then dismiss(i, false) end
    end
  end
end

function M.start()
  _G.claudeNotify = M
  os.execute("mkdir -p " .. string.format("%q", INBOX))
  hs.fs.mkdir(INBOX)
  hs.fs.mkdir(SHOWN)
  -- FSEvents can coalesce two quick drops into one event that fires before the
  -- second rename lands, so look again a moment later.
  activeWatchers.claudeNotifyWatcher = hs.pathwatcher.new(INBOX, function()
    scanInbox()
    activeWatchers.claudeNotifyRescan = hs.timer.doAfter(1, scanInbox)
  end)
  activeWatchers.claudeNotifyWatcher:start()
  activeWatchers.claudeNotifyTick = hs.timer.doEvery(1, tick)
  local f = io.open(INBOX .. "/.loaded", "w")
  if f then f:write(VERSION .. " " .. os.date("!%H:%M:%S")); f:close() end
  scanInbox()   -- anything that arrived while Hammerspoon was off
end

function M.stop()
  if activeWatchers.claudeNotifyWatcher then activeWatchers.claudeNotifyWatcher:stop() end
  if activeWatchers.claudeNotifyTick then activeWatchers.claudeNotifyTick:stop() end
  for i = 1, MAX_SLOTS do
    if slots[i] then slots[i].canvas:delete() end
    slots[i] = nil
  end
end

return M
