-- ~/.hammerspoon/modules/claude_control.lua
-- "Claude wants to take control" banner.
--
-- Before an agent posts synthetic keyboard/mouse events (smoke tests of
-- controller code, app switching, etc.) it asks here first, so Matt's own
-- typing doesn't collide with the test and he knows why his Mac is moving.
--
--   claudeControl.ask(reason, seconds, urgent, quiet, agent, pid, light, link) -- returns a ticket id ("t7")
--   claudeControl.state(id)  -- "queued:N" | "pending" | "granted" | "snoozed:S" | "cancelled" | "stopped" | "preempted" | "idle"
--   claudeControl.snooze(secs) -- holder steps aside for secs, then goes back to the front of the queue
--   claudeControl.done(id)   -- release (or leave the queue); the next agent in line gets the banner
--   claudeControl.lock(name, urgent)      -- same queue, no banner: for deterministic automations
--   claudeControl.withInput(name, fn)     -- Hammerspoon modules: run fn(release) when it's our turn
--
-- Air traffic control: several agents on the Mac may ask at once, so asks
-- queue and only one holds the banner (and the keyboard/mouse) at a time.
-- An urgent ask (stopping a runaway) jumps the line and preempts a normal
-- holder, whose state turns "preempted" so its script stops.
-- Escape (or "Not now") cancels the holder and everyone queued.
-- Stop (Esc twice, or the "Stop task" button) is a hard no: the holder's
-- state turns "stopped", its agent (Claude session id) is blocked from asking
-- again for BLOCK_SECS (every later ask returns "stopped" at once), and its
-- claude process gets SIGINT, which aborts the session's current turn. The
-- SIGINT goes only to a granted holder (it's acting): a pending ask's wrapper
-- already returns "stopped", and SIGINT to a Claude session between turns
-- exits the whole process, which leaves a Remote Control thread deaf to new
-- messages (2026-10-23).
-- A holder auto-releases after MAX_HOLD seconds; a queued ask nobody has
-- polled for QUEUE_IDLE seconds is dropped (its agent died).
-- Two tiers (Matt, 2026-10-21: full glow only when he must keep hands off):
--   full  (default): centre banner + soft orange edge glow. Agent types, clicks
--                    or moves the mouse: Matt must keep his hands off.
--   light (--light): small pill in the "claude_control_light" HUD slot, no glow.
--                    Low-impact screen/sound changes (open a file or app, focus a
--                    window, play/pause, volume, restart audio) Matt can keep
--                    typing through. Same queue, same Esc / Esc Esc / Stop.
--                    Snooze chips (30s / 1m / 5m) put the ask aside (Matt, 2026-10-22).
-- link (--link / --thread): clicking the banner body opens the asking agent's
-- thread or session, so Matt can see who wants control and why.
-- Agents use the wrapper: ~/.hammerspoon/bin/claude-control ask "<reason>" [secs] [--light] [--thread cmsg_…]

-- Feel knobs (⌃⌥⌘T Tweaks panel); found by bin/tweaks scan, kept by prune.
local TWEAKS = {
  ["timing.stopWindow"] = { 3, min = 1, max = 8, step = 0.5, note = "Seconds after Esc in which a second Esc means Stop" },
  ["glow.rimWidth"] = { 4, min = 0, max = 12, step = 0.5, note = "Thickness of the solid screen-edge rim in points" },
  ["glow.pulseBase"] = { 0.85, min = 0.4, max = 1, step = 0.01, note = "Average brightness of the pulsing screen-edge glow" },
  ["look.pillRadius"] = { 13, min = 0, max = 31, step = 1, note = "Corner roundness of the small ask pill in points" },
  ["look.pillOpacity"] = { 0.98, min = 0.5, max = 1, step = 0.01, note = "Opacity of the small ask pill background" },
  ["look.pillBorderWidth"] = { 1.5, min = 0, max = 5, step = 0.5, note = "Border thickness of the small ask pill in points" },
  ["look.bannerRadius"] = { 16, min = 0, max = 40, step = 1, note = "Corner roundness of the full banner in points" },
  ["look.bannerOpacity"] = { 0.95, min = 0.5, max = 1, step = 0.01, note = "Opacity of the full banner background" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Claude Take-Control Banner",
  file = require("modules.tweaks").dir .. "/claude_control.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "claude_control",
  name = "Claude Take-Control Banner"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

require("hs.canvas")
require("hs.eventtap")

local MAX_HOLD = 60
local QUEUE_IDLE = 15
-- An agent's ask whose wrapper stopped polling this long is an orphan: the wrapper
-- gave up ("hammerspoon unreachable" when hs -c was slow under memory pressure)
-- but the ask still landed. It's dropped, never shown or granted, so Matt can't
-- Stop an agent that isn't waiting (2026-10-23: that SIGINT killed an idle thread).
local ORPHAN_SECS = 8
local BLOCK_SECS = 2 * 3600

local layout = require("modules.hud_layout")

local state = "idle"     -- the banner holder's state
local lightMode = false  -- the holder's tier
local reasonText = ""
local remaining = 0

local tickets = {}       -- id -> { reason, seconds, urgent, state, seen }
local queue = {}         -- ids waiting their turn, in order
local active = nil       -- id holding the banner
local nextId = 0
local byKey = {}         -- wrapper request key -> id, so a retried ask isn't a second ticket

-- An agent ticket nobody is polling (see ORPHAN_SECS). Demo/lock tickets have no poller.
local function isOrphan(t)
  return t and t.agent and t.agent ~= "" and not t.quiet
    and hs.timer.secondsSinceEpoch() - (t.seen or 0) > ORPHAN_SECS
end

-- agent key -> unblock time (epoch secs); kept in hs.settings so a
-- Hammerspoon reload doesn't let a stopped agent back in.
local BLOCK_KEY = "claudeControl.blocked"
local blocked = hs.settings.get(BLOCK_KEY) or {}
local function saveBlocked() hs.settings.set(BLOCK_KEY, blocked) end
local function isBlocked(agent)
  if not agent or agent == "" then return false end
  local untilT = blocked[agent]
  if untilT and untilT > hs.timer.secondsSinceEpoch() then return true end
  if untilT then blocked[agent] = nil; saveBlocked() end
  return false
end

local function setState(s)
  state = s
  if active and tickets[active] then tickets[active].state = s end
end

local function hideGlow()
  for _, c in ipairs(activeWatchers.claudeControlGlow or {}) do c:delete() end
  activeWatchers.claudeControlGlow = nil
  if activeWatchers.claudeControlPulse then
    activeWatchers.claudeControlPulse:stop()
    activeWatchers.claudeControlPulse = nil
  end
end

-- Soft orange glow on the inner 8% of every screen: visible, not alarming.
-- Click-through (no mouse callback), pulses gently.
local function glowColor(a) return { red = 1.0, green = 0.48, blue = 0.10, alpha = a } end

local function drawGlow()
  hideGlow()
  local list = {}
  for _, scr in ipairs(hs.screen.allScreens()) do
    local f = scr:fullFrame()
    local gw, gh = math.floor(f.w * 0.08), math.floor(f.h * 0.08)
    local c = hs.canvas.new(f)
    c:level(hs.canvas.windowLevels.screenSaver)
    c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    local edge, inner = glowColor(0.5), glowColor(0.0)
    c:appendElements(
      -- top: edge colour at y=0 fading down
      { type = "rectangle", action = "fill", frame = { x = 0, y = 0, w = f.w, h = gh },
        fillGradient = "linear", fillGradientColors = { edge, inner }, fillGradientAngle = 90 },
      -- bottom
      { type = "rectangle", action = "fill", frame = { x = 0, y = f.h - gh, w = f.w, h = gh },
        fillGradient = "linear", fillGradientColors = { edge, inner }, fillGradientAngle = 270 },
      -- left
      { type = "rectangle", action = "fill", frame = { x = 0, y = 0, w = gw, h = f.h },
        fillGradient = "linear", fillGradientColors = { edge, inner }, fillGradientAngle = 0 },
      -- right
      { type = "rectangle", action = "fill", frame = { x = f.w - gw, y = 0, w = gw, h = f.h },
        fillGradient = "linear", fillGradientColors = { edge, inner }, fillGradientAngle = 180 },
      -- solid rim
      { type = "rectangle", action = "stroke", frame = { x = 0, y = 0, w = f.w, h = f.h },
        strokeColor = glowColor(0.8), strokeWidth = T("glow.rimWidth") }
    )
    c:show()
    list[#list + 1] = c
  end
  activeWatchers.claudeControlGlow = list
  local t = 0
  activeWatchers.claudeControlPulse = hs.timer.doEvery(0.05, function()
    t = t + 0.05
    local a = T("glow.pulseBase") + 0.15 * math.sin(t * 2.5)
    for _, c in ipairs(list) do c:alpha(a) end
  end)
end

local function hideBanner()
  hideGlow()
  if activeWatchers.claudeControlCanvas then
    activeWatchers.claudeControlCanvas:delete()
    activeWatchers.claudeControlCanvas = nil
  end
  if activeWatchers.claudeControlTimer then
    activeWatchers.claudeControlTimer:stop()
    activeWatchers.claudeControlTimer = nil
  end
  if activeWatchers.claudeControlEsc then
    activeWatchers.claudeControlEsc:stop()
    activeWatchers.claudeControlEsc = nil
  end
end

local advance  -- defined below

local function disarmStop()
  if activeWatchers.claudeControlStopTap then
    activeWatchers.claudeControlStopTap:stop()
    activeWatchers.claudeControlStopTap = nil
  end
  if activeWatchers.claudeControlStopTimer then
    activeWatchers.claudeControlStopTimer:stop()
    activeWatchers.claudeControlStopTimer = nil
  end
end

local function isRealEsc(e)
  return e:getKeyCode() == hs.keycodes.map.escape
    and e:getProperty(hs.eventtap.event.properties.eventSourceUserData) == 0
end

-- Interrupt the asking Claude session: SIGINT aborts its current turn (the
-- desktop app settles the session as stopped). Only signals a live process
-- named claude, so a reused pid can't hit something else.
local function interruptAgent(pid)
  pid = tonumber(pid)
  if not pid or pid <= 1 then return false end
  local comm = hs.execute("/bin/ps -o comm= -p " .. pid) or ""
  if not comm:match("claude%s*$") then return false end
  hs.execute("/bin/kill -INT " .. pid)
  return true
end

-- Matt's hard no: block this ticket's agent and end its turn.
local function stopTicket(id)
  disarmStop()
  local t = id and tickets[id]
  if not t then return end
  if id == active then hideBanner(); active = nil; state = "idle" end
  local wasGranted = t.state == "granted"
  t.state = "stopped"
  if t.agent and t.agent ~= "" then
    blocked[t.agent] = hs.timer.secondsSinceEpoch() + BLOCK_SECS
    saveBlocked()
  end
  -- Give a polling wrapper a moment to read "stopped" before the signal.
  local pid = t.pid
  if wasGranted then hs.timer.doAfter(0.6, function() interruptAgent(pid) end) end
  hs.alert.show("Claude's task stopped. It can't ask for control again.", 2)
  advance()
end

-- Matt pressed Esc ("not now"): cancel the holder and everyone waiting. For
-- STOP_WINDOW seconds a second Esc upgrades it to Stop for the holder.
local function cancel()
  local id = active
  hideBanner()
  setState("cancelled")
  active = nil
  for _, q in ipairs(queue) do tickets[q].state = "cancelled" end
  queue = {}
  disarmStop()
  if not (id and tickets[id] and not tickets[id].quiet) then
    hs.alert.show("Claude paused. You have control.", 1.2)
    return
  end
  local alertId = hs.alert.show("Claude paused. Press Esc again to stop its task.", T("timing.stopWindow"))
  local tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if isRealEsc(e) then
      hs.alert.closeSpecific(alertId)
      stopTicket(id)
      return true
    end
    return false
  end)
  tap:start()
  activeWatchers.claudeControlStopTap = tap
  activeWatchers.claudeControlStopTimer = hs.timer.doAfter(T("timing.stopWindow"), disarmStop)
end

-- Long reasons wrap instead of truncating: the wrapping text element grows to
-- as many lines as it needs, everything below it moves down, and the canvas
-- grows taller (light pill: top edge stays put; full banner: stays centred).
-- Canvas text has no "lines needed for this width" query, so wrap greedily by
-- word with hs.drawing.getTextDrawingSize, a little narrower than the frame so
-- AppKit never needs more lines than we counted.
local function wrappedHeight(text, font, size, width)
  local style = { font = font, size = size }
  local function wide(s) return hs.drawing.getTextDrawingSize(s, style).w end
  local lineH = hs.drawing.getTextDrawingSize("Ag", style).h
  local lines, line = 1, ""
  for word in tostring(text):gmatch("%S+") do
    local try = line == "" and word or (line .. " " .. word)
    if wide(try) <= width - 6 then
      line = try
    else
      if line ~= "" then lines = lines + 1 end
      line = word
      while wide(line) > width - 6 and #line > 1 do  -- a word wider than the box breaks by character
        local n = #line
        while n > 1 and wide(line:sub(1, n)) > width - 6 do n = n - 1 end
        lines, line = lines + 1, line:sub(n + 1)
      end
    end
  end
  return math.ceil(lines * lineH) + 2
end

-- Each canvas records its wrapping elements and their base frames when built
-- (activeWatchers.claudeControlFit = { base = {h}, frames = {...}, wraps = {i...} }).
local function fitText(c)
  local fit = activeWatchers.claudeControlFit
  if not fit or fit.canvas ~= c then return end
  local shifts = {}  -- { bottom = base bottom of a wrapping element, extra = px }
  local total = 0
  for _, i in ipairs(fit.wraps) do
    local f = fit.frames[i]
    local need = wrappedHeight(c[i].text, c[i].textFont, c[i].textSize, f.w)
    local extra = math.max(0, need - f.h)
    c[i].frame = { x = f.x, y = f.y + total, w = f.w, h = f.h + extra }
    shifts[#shifts + 1] = { bottom = f.y + f.h, extra = extra }
    total = total + extra
  end
  for i, f in pairs(fit.frames) do
    local isWrap = false
    for _, k in ipairs(fit.wraps) do if k == i then isWrap = true end end
    if not isWrap then
      local dy = 0
      for _, s in ipairs(shifts) do if f.y >= s.bottom then dy = dy + s.extra end end
      c[i].frame = { x = f.x, y = f.y + dy, w = f.w, h = f.h }
    end
  end
  local cur = c:frame()
  local h = fit.base.h + total
  if cur.h ~= h then
    local y = fit.centred and (cur.y + (cur.h - h) / 2) or cur.y
    c:frame({ x = cur.x, y = y, w = cur.w, h = h })
  end
end

-- Remember element frames (all but the full-size background at index 1).
local function trackFit(c, wraps, centred)
  local frames = {}
  for i = 2, #c do
    local f = c[i].frame
    frames[i] = { x = f.x, y = f.y, w = f.w, h = f.h }
  end
  activeWatchers.claudeControlFit = { canvas = c, base = { h = c:frame().h }, frames = frames,
                                      wraps = wraps, centred = centred }
end

local function render()
  local c = activeWatchers.claudeControlCanvas
  if not c then return end
  local title, sub
  if lightMode then
    title = state == "pending" and string.format("Claude, in %d: %s", remaining, reasonText)
      or ("Claude: " .. reasonText)
    local t = active and tickets[active]
    sub = (t and t.link) and "Click: open thread  ·  Esc not now" or "Esc not now  ·  Esc Esc stop"
  elseif state == "pending" then
    title = string.format("Claude wants to take control in %d…", remaining)
    sub = reasonText .. "  ·  Hands off the keyboard and mouse."
  else
    title = "Claude is controlling your Mac"
    sub = reasonText
  end
  c[2].text = title
  c[3].text = sub
  fitText(c)
end

-- Light tier: a small translucent pill in its HUD slot. Element order matches
-- the full banner (2 = title, 3 = sub) so render() works for both.
-- Row 1: title + Stop. Row 2: hint + snooze chips (30s / 1m / 5m).
local SNOOZES = { { id = "snooze30", label = "30s", secs = 30 }, { id = "snooze60", label = "1m", secs = 60 },
                  { id = "snooze300", label = "5m", secs = 300 } }
local function lightCanvas()
  local w, h = 432, 62   -- 20% bigger than the first pill (360x52), same text sizes
  local c = hs.canvas.new(layout.rect("claude_control_light", w, h))
  local chipW, chipGap = 38, 4
  local chipsX = w - 12 - #SNOOZES * chipW - (#SNOOZES - 1) * chipGap
  c:appendElements(
    { id = "body", type = "rectangle", action = "fill", trackMouseDown = true,
      roundedRectRadii = { xRadius = T("look.pillRadius"), yRadius = T("look.pillRadius") },
      fillColor = { hex = "#FFF6E5", alpha = T("look.pillOpacity") }, strokeColor = { hex = "#FF7A1A", alpha = 0.8 },
      strokeWidth = T("look.pillBorderWidth") },
    { type = "text", text = "", frame = { x = 14, y = 10, w = w - 98, h = 20 },
      textSize = 13, textColor = { hex = "#3B2A12" }, textFont = ".AppleSystemUIFontBold",
      textLineBreak = "wordWrap" },
    { type = "text", text = "", frame = { x = 14, y = 37, w = chipsX - 66, h = 16 },
      textSize = 11, textColor = { hex = "#6B5330" }, textLineBreak = "truncateTail" },
    { id = "stop", type = "rectangle", action = "fill", trackMouseDown = true,
      frame = { x = w - 72, y = 8, w = 60, h = 24 },
      roundedRectRadii = { xRadius = 7, yRadius = 7 }, fillColor = { hex = "#FF7A1A" } },
    { type = "text", text = "Stop", frame = { x = w - 72, y = 11, w = 60, h = 18 },
      textSize = 12, textColor = { hex = "#3B2A12" }, textFont = ".AppleSystemUIFontBold",
      textAlignment = "center" },
    { type = "text", text = "Snooze", frame = { x = chipsX - 50, y = 37, w = 46, h = 16 },
      textSize = 11, textColor = { hex = "#6B5330" }, textAlignment = "right" }
  )
  for i, s in ipairs(SNOOZES) do
    local x = chipsX + (i - 1) * (chipW + chipGap)
    c:appendElements(
      { id = s.id, type = "rectangle", action = "fill", trackMouseDown = true,
        frame = { x = x, y = 35, w = chipW, h = 20 },
        roundedRectRadii = { xRadius = 6, yRadius = 6 }, fillColor = { hex = "#F1E2C6" } },
      { type = "text", text = s.label, frame = { x = x, y = 37, w = chipW, h = 16 },
        textSize = 11, textColor = { hex = "#3B2A12" }, textAlignment = "center" })
  end
  return c
end

local function fullCanvas()
  local screen = hs.screen.mainScreen():frame()
  local w, h = 560, 118
  local frame = { x = screen.x + (screen.w - w) / 2, y = screen.y + (screen.h - h) / 2, w = w, h = h }
  local c = hs.canvas.new(frame)
  c:appendElements(
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = T("look.bannerRadius"), yRadius = T("look.bannerRadius") },
      fillColor = { hex = "#FFF6E5", alpha = T("look.bannerOpacity") } },
    { type = "text", text = "", frame = { x = 20, y = 16, w = w - 40, h = 26 },
      textSize = 19, textColor = { hex = "#3B2A12" }, textFont = ".AppleSystemUIFontBold",
      textAlignment = "center" },
    { type = "text", text = "", frame = { x = 20, y = 46, w = w - 40, h = 20 },
      textSize = 13, textColor = { hex = "#6B5330" }, textAlignment = "center",
      textLineBreak = "wordWrap" },
    { id = "notnow", type = "rectangle", action = "fill", trackMouseDown = true,
      frame = { x = w / 2 - 170, y = 76, w = 160, h = 28 },
      roundedRectRadii = { xRadius = 8, yRadius = 8 }, fillColor = { hex = "#F1E2C6" } },
    { type = "text", text = "Not now  ·  Esc", frame = { x = w / 2 - 170, y = 81, w = 160, h = 18 },
      textSize = 12, textColor = { hex = "#3B2A12" }, textAlignment = "center" },
    { id = "stop", type = "rectangle", action = "fill", trackMouseDown = true,
      frame = { x = w / 2 + 10, y = 76, w = 160, h = 28 },
      roundedRectRadii = { xRadius = 8, yRadius = 8 }, fillColor = { hex = "#FF7A1A" } },
    { type = "text", text = "Stop task  ·  Esc Esc", frame = { x = w / 2 + 10, y = 81, w = 160, h = 18 },
      textSize = 12, textColor = { hex = "#3B2A12" }, textFont = ".AppleSystemUIFontBold",
      textAlignment = "center" }
  )
  return c
end

local function drawBanner()
  local c = lightMode and lightCanvas() or fullCanvas()
  c:level(hs.canvas.windowLevels.screenSaver)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  c:mouseCallback(function(_, _, elementId)
    -- Defer: deleting the canvas inside its own callback is unsafe.
    hs.timer.doAfter(0, function()
      local t = active and tickets[active]
      local secs = tostring(elementId):match("^snooze(%d+)$")
      if elementId == "stop" then stopTicket(active)
      elseif secs then M.snooze(tonumber(secs))
      elseif elementId ~= "notnow" and t and t.link then require("modules.claude_links").open(t.link)
      else cancel() end
    end)
  end)
  c:canvasMouseEvents(true, false, false, false)
  -- Light: the title (reason) wraps. Full: title and reason both may wrap.
  if lightMode then trackFit(c, { 2 }, false) else trackFit(c, { 2, 3 }, true) end
  if not lightMode then drawGlow() end
  c:show()
  activeWatchers.claudeControlCanvas = c
end

local function begin(reason, seconds, light)
  hideBanner()
  lightMode = light and true or false
  if activeWatchers.claudeControlEsc then activeWatchers.claudeControlEsc:stop() end
  reasonText = reason or "Running a quick test"
  remaining = math.max(1, math.floor(tonumber(seconds) or 3))
  setState("pending")
  drawBanner()
  render()

  local esc = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    -- Only real key presses; ignore the synthetic events the agent posts
    if isRealEsc(e) then
      cancel()
      return true
    end
    return false
  end)
  esc:start()
  activeWatchers.claudeControlEsc = esc

  local held = 0
  activeWatchers.claudeControlTimer = hs.timer.doEvery(1, function()
    if state == "pending" then
      local t = tickets[active]
      if isOrphan(t) then
        print("claude_control: dropped orphaned ask from " .. tostring(t.agent) .. ": " .. tostring(t.reason))
        t.state = "dropped"
        M.done(active)
        return
      end
      -- An agent's ask is granted only once its wrapper has polled: a wrapper that
      -- gave up never polls, so its ticket waits here and is dropped as an orphan.
      local waiting = t and t.agent and t.agent ~= "" and not t.quiet and not t.polled
      if remaining > 1 or not waiting then remaining = remaining - 1 end
      if remaining <= 0 then setState("granted") end
      render()
    elseif state == "granted" then
      held = held + 1
      if held >= MAX_HOLD then M.done(active) end
    end
  end)
end

-- Give the banner to the next ticket in line. Runs on a timer: building the
-- canvas/eventtap inside an `hs -c` IPC call hung Hammerspoon (hs.ipc
-- "already recursing").
advance = function()
  if active then return end
  local id = table.remove(queue, 1)
  if not id then return end
  active = id
  local t = tickets[id]
  if t.quiet then  -- deterministic automation: no banner, no countdown
    state = "granted"
    t.state = "granted"
    local held = 0
    if activeWatchers.claudeControlTimer then activeWatchers.claudeControlTimer:stop() end
    activeWatchers.claudeControlTimer = hs.timer.doEvery(1, function()
      held = held + 1
      if held >= MAX_HOLD and active == id then M.done(id) end
    end)
    return
  end
  state = "pending"
  t.state = "pending"
  activeWatchers.claudeControlStart = hs.timer.doAfter(0, function()
    if active ~= id then return end
    local ok, err = pcall(begin, t.reason, t.seconds, t.light)
    if not ok then
      print("claude_control: " .. tostring(err))
      hideBanner()
      setState("error")
      active = nil
      advance()
    end
  end)
end

function M.ask(reason, seconds, urgent, quiet, agent, pid, light, link, key)
  if key and byKey[key] and tickets[byKey[key]] then
    tickets[byKey[key]].seen = hs.timer.secondsSinceEpoch()
    return byKey[key]
  end
  nextId = nextId + 1
  local id = "t" .. nextId
  tickets[id] = { reason = reason or "Running a quick test", seconds = seconds, urgent = urgent and true or false,
                  quiet = quiet and true or false, state = "queued", seen = hs.timer.secondsSinceEpoch(),
                  agent = agent, pid = pid, light = light and true or false,
                  link = require("modules.claude_links").resolve(link) }
  if key then byKey[key] = id end
  if not quiet and isBlocked(agent) then
    tickets[id].state = "stopped"
    print("claude_control: refused ask from stopped agent " .. tostring(agent) .. ": " .. tostring(reason))
    return id
  end
  if urgent then
    if active and not tickets[active].urgent then
      hideBanner()
      setState("preempted")
      active = nil
    end
    table.insert(queue, 1, id)
  else
    table.insert(queue, id)
  end
  advance()
  return id
end

-- Deterministic automations (Hammerspoon, Keyboard Maestro, scripts) share the
-- same queue without the banner, so they never type over an agent or each other.
function M.lock(name, urgent)
  return M.ask(name or "automation", 0, urgent, true)
end

-- For Hammerspoon modules: runs fn(release) right away if nobody holds input,
-- else when its turn comes. Call release() when done (it's also called if fn
-- returns without taking the argument, i.e. fn has no async steps).
function M.withInput(name, fn)
  local id = M.lock(name)
  local function release() M.done(id) end
  local function go()
    local ok, err = pcall(fn, release)
    if not ok then print("claude_control withInput " .. tostring(name) .. ": " .. tostring(err)) end
    if debug.getinfo(fn, "u").nparams == 0 or not ok then release() end
  end
  if active == id then return go() end
  local poll
  poll = hs.timer.doEvery(0.1, function()
    local t = tickets[id]
    if not t then poll:stop(); return end
    t.seen = hs.timer.secondsSinceEpoch()
    if active == id and t.state == "granted" then poll:stop(); go()
    elseif t.state ~= "queued" and t.state ~= "pending" and t.state ~= "granted" then poll:stop() end
  end)
end

function M.state(id)
  id = id or active
  local t = id and tickets[id]
  if not t then return "idle" end
  t.seen = hs.timer.secondsSinceEpoch()
  t.polled = true
  if t.state == "queued" then
    for i, q in ipairs(queue) do if q == id then return "queued:" .. i end end
  end
  if t.state == "snoozed" then
    return "snoozed:" .. math.max(0, math.ceil((t.wake or 0) - hs.timer.secondsSinceEpoch()))
  end
  -- "pending" with no banner drawn yet reads as "starting"
  if id == active and t.state == "pending" and not activeWatchers.claudeControlCanvas then return "starting" end
  return t.state
end

function M.done(id)
  id = id or active
  if id and id == active then
    hideBanner()
    setState("done")
    active = nil
    state = "idle"
    advance()
  elseif id and tickets[id] then
    for i, q in ipairs(queue) do if q == id then table.remove(queue, i) break end end
    tickets[id].state = "done"
  end
  return "idle"
end

-- Matt: "ask me again in secs". The holder steps aside (the next agent in line
-- gets its turn), then rejoins at the front of the queue. Its wrapper keeps waiting.
function M.snooze(secs)
  local id = active
  local t = id and tickets[id]
  if not t then return "idle" end
  secs = tonumber(secs) or 60
  hideBanner()
  active, state = nil, "idle"
  t.state = "snoozed"
  t.wake = hs.timer.secondsSinceEpoch() + secs
  activeWatchers["claudeControlSnooze_" .. id] = hs.timer.doAfter(secs, function()
    activeWatchers["claudeControlSnooze_" .. id] = nil
    if tickets[id] ~= t or t.state ~= "snoozed" then return end
    t.state = "queued"
    t.seen = hs.timer.secondsSinceEpoch()   -- a dead agent is then dropped by the reaper
    table.insert(queue, 1, id)
    advance()
  end)
  advance()
  return "snoozed:" .. secs
end

-- Drop queued asks whose agent stopped polling, and forget old tickets.
if activeWatchers.claudeControlReaper then activeWatchers.claudeControlReaper:stop() end
activeWatchers.claudeControlReaper = hs.timer.doEvery(5, function()
  local now = hs.timer.secondsSinceEpoch()
  for i = #queue, 1, -1 do
    local t = tickets[queue[i]]
    if now - t.seen > QUEUE_IDLE then t.state = "dropped"; table.remove(queue, i) end
  end
  for id, t in pairs(tickets) do
    if id ~= active and t.state ~= "queued" and now - t.seen > 300 then tickets[id] = nil end
  end
  for k, id in pairs(byKey) do
    if not tickets[id] then byKey[k] = nil end
  end
end)

-- The wrapper gave up on an ask: drop whatever ticket it may have made.
function M.forget(key)
  local id = key and byKey[key]
  if not id or not tickets[id] then return "none" end
  local t = tickets[id]
  if id == active then M.done(id)
  elseif t.state == "queued" or t.state == "snoozed" then
    for i, q in ipairs(queue) do if q == id then table.remove(queue, i) break end end
  end
  t.state = "dropped"
  return "dropped"
end

-- What the banner's Stop does, for the holder (or a given ticket).
function M.stopTicket(id) stopTicket(id or active) end

-- Does this agent hold control right now? "granted" | "pending" | "none".
-- The PreToolUse input guard asks this before letting `open`/activate run.
function M.heldBy(agent)
  local t = active and tickets[active]
  if t and agent and t.agent == agent and (t.state == "granted" or t.state == "pending") then
    t.seen = hs.timer.secondsSinceEpoch()
    return t.state
  end
  return "none"
end

-- Let a stopped agent ask again: unblock(agent), or unblock() for all.
function M.unblock(agent)
  if agent then blocked[agent] = nil else blocked = {} end
  saveBlocked()
  return "ok"
end

function M.blocked()
  local now, out = hs.timer.secondsSinceEpoch(), {}
  for a, u in pairs(blocked) do
    if u > now then out[#out + 1] = string.format("%s %dm", a, math.ceil((u - now) / 60)) end
  end
  return #out > 0 and table.concat(out, ", ") or "none"
end

-- Preview a tier yourself (Matt): opens the real banner with no agent behind
-- it, then releases after a few seconds. Esc / Stop work as usual.
--   hammerspoon://claude-control-demo?tier=light   (or tier=full; &text=… for a custom reason)
function M.demo(tier, link, text)
  local light = tier == "light"
  local id = M.ask((text and text ~= "") and text
                   or (light and "Preview: opening an app (light tier)" or "Preview: typing a test (full tier)"),
                   3, false, false, nil, nil, light, link)
  hs.timer.doAfter(8, function()
    local t = tickets[id]
    if t and (t.state == "pending" or t.state == "granted" or t.state == "queued") then M.done(id) end
  end)
  return id
end

function M.start()
  _G.claudeControl = M
  hs.urlevent.bind("claude-control-demo", function(_, params) M.demo(params and params.tier, params and params.link, params and params.text) end)
end

function M.stop()
  hs.urlevent.bind("claude-control-demo", nil)
  disarmStop()
  hideBanner()
  setState("idle")
  active, queue = nil, {}
end

return M
