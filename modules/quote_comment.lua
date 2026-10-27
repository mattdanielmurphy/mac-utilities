-- ~/.hammerspoon/modules/quote_comment.lua
-- Batch "quote + dictated comment" for Claude.app, sent as one message.
--
--   ⌥R    highlight text (in Claude or anywhere) → it goes into Claude's message box
--         as "> quote" with the cursor under it, and ⌘D starts Claude dictation.
--         Talk, then Return: the quote + comment moves to a hidden queue and the box
--         clears (dictation is stopped first). ⌥R on the next highlight does the same
--         if you skipped the Return.
--   ⌥⇧R   queue the highlighted text with no comment (the box is left alone)
--   ⌥⌘R   put the queue back into the box now, without sending
--
-- Plain Return in Claude's message box (no quote in it) with anything queued puts
-- the queue above what's in the box, in order, then sends. ⌘Return sends everything
-- now, including a quote + comment still in the box. With nothing queued or pending
-- Return is never touched; nor is Shift/⌥/⌃+Return, or a message that starts with "/".
-- A bar sits on Claude's window while a quote is in the box or anything is queued:
-- "❝ N queued" (click for insert now / show / remove last / clear), then two buttons,
-- "Queue ⏎" (what Return does to a quote + comment) and "Send all ⌘⏎".
-- Every synthetic key goes through claudeControl.withInput, so it never types over
-- an agent that holds the keyboard.
-- The older comment-box version (WYSIWYG webview) is in archive/quote_comment.lua.

local M = {
  id = "quote_comment",
  name = "Quote → Dictated comment queue for Claude (⌥R)",
  dictate = true, -- press ⌘D after inserting a quote
  -- Claude dictation strips leading whitespace, so a bare "\n\n" after the quote
  -- gets eaten and the comment joins the quote. A visible marker keeps them apart.
  marker = "↳ "
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"
local SETTINGS_KEY = "quote_comment_queue"
local MAGIC = 0x51C0 -- marks Return events we synthesize so our tap ignores them
local RETURN = hs.keycodes.map["return"]
local PADENTER = hs.keycodes.map["padenter"]

local log = hs.logger.new("quote_cmt", "info")

local updateBadge -- forward decl

-- Feel knobs: ~/.hammerspoon/tweaks/quote_comment.json, or the Tweaks panel (⌃⌥⌘T).
local T = require("modules.tweaks").open{
  app = "Quote comments (⌥R)",
  file = require("modules.tweaks").dir .. "/quote_comment.json",
  knobs = {
    ["look.queueBorderWidth"] = { 2, min = 0.5, max = 5, step = 0.5, note = "Thickness of the queue button outline in points" },
    ["look.sendBorderWhite"] = { 0.55, min = 0, max = 1, step = 0.05, note = "Brightness of the Send all button border (0 black, 1 white)" },
    ["look.sendTextWhite"] = { 0.15, min = 0, max = 1, step = 0.05, note = "Brightness of the Send all button label (0 black, 1 white)" },
    ["bar.right"]    = { 24, min = 0, max = 400, step = 2, note = "Bar's distance from Claude's right edge (px)" },
    ["bar.bottom"]   = { 130, min = 0, max = 600, step = 2, note = "Bar's distance from Claude's bottom edge (px)" },
    ["bar.height"]   = { 26, min = 18, max = 44, step = 1, note = "Bar height (px)" },
    ["bar.gap"]      = { 6, min = 0, max = 20, step = 1, note = "Gap between the pill and buttons (px)" },
    ["bar.text"]     = { 13, min = 9, max = 20, step = 0.5, note = "Label size (pt)" },
    ["look.accent"]  = { "#2b5f75", note = "Pill and default-button colour (deep teal)" },
    ["look.alpha"]   = { 0.9, min = 0.2, max = 1, step = 0.05, note = "Bar opacity" },
    ["send.guard"]   = { 1.5, min = 0, max = 5, step = 0.1, note = "Seconds after queueing a comment when plain Return won't send (stops a double-tap sending)" },
    ["look.dimAlpha"] = { 0.35, min = 0, max = 1, step = 0.05, note = "Opacity of Queue when there's nothing to queue" },
  },
  onChange = function() if updateBadge then updateBadge() end end,
}

-- ── Helpers ─────────────────────────────────────────────────────────────────────

local function safeAttr(el, name)
  if not el then return nil end
  local ok, v = pcall(function() return el:attributeValue(name) end)
  if ok then return v end
  return nil
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function formatQuote(text)
  text = trim(text:gsub("\r\n?", "\n")):gsub("\n\n\n+", "\n\n")
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = (line == "") and ">" or ("> " .. line)
  end
  return table.concat(out, "\n")
end

local function now() return hs.timer.absoluteTime() / 1e6 end -- ms

-- Poll without blocking Hammerspoon's main thread. cb(true) when cond() holds, cb(false) on timeout.
local function pollUntil(cond, timeoutMs, cb, every)
  local start = now()
  if cond() then cb(true); return end
  local t
  t = hs.timer.doEvery(every or 0.015, function()
    if cond() then t:stop(); cb(true)
    elseif now() - start > timeoutMs then t:stop(); cb(false) end
  end)
end

local function after(sec, fn) hs.timer.doAfter(sec, fn) end

local function modifiersHeld()
  local m = hs.eventtap.checkKeyboardModifiers()
  return m.alt or m.cmd or m.shift or m.ctrl
end

local function key(mods, k) hs.eventtap.keyStroke(mods, k, 0) end

-- Wait for the keyboard: runs fn(release) once no agent or automation holds input.
local function withInput(fn)
  local ok, cc = pcall(require, "modules.claude_control")
  if ok and type(cc) == "table" and cc.withInput then return cc.withInput("quote_comment", fn) end
  fn(function() end)
end

local function claudeApp() return hs.application.applicationsForBundleID(CLAUDE_BUNDLE)[1] end

-- ── Queue (persisted so a config reload doesn't lose it) ───────────────────────

local queue = hs.settings.get(SETTINGS_KEY) or {}
local pending = nil -- { composer = AX element } while a quote we put in is in Claude's box
local lastQueued = 0 -- ms; a Return this soon after a queue is swallowed (double-tap guard)

local function saveQueue()
  hs.settings.set(SETTINGS_KEY, queue)
  updateBadge()
end

-- Blank line before the "↳" comment line, so markdown doesn't fold the comment
-- into the blockquote. The box's AXValue drops empty paragraphs, so saved text
-- comes back as "> quote\n↳ comment".
local function spaceComment(text)
  local m = trim(M.marker):gsub("%p", "%%%0")
  return (text:gsub("\n+(" .. m .. ")", "\n\n%1"))
end

-- Items are { text = <box contents> } (dictated) or { quote, comment } (⌥⇧R / older queue).
local function itemText(item)
  if item.text then return spaceComment(item.text) end
  local block = formatQuote(item.quote)
  if item.comment and item.comment ~= "" then block = block .. "\n\n" .. item.comment end
  return block
end

local function queueText()
  local parts = {}
  for _, item in ipairs(queue) do parts[#parts + 1] = itemText(item) end
  return table.concat(parts, "\n\n")
end

local function clearQueue()
  queue = {}
  saveQueue()
end

-- ── Selection capture ──────────────────────────────────────────────────────────

-- cb(text_or_nil, savedClipboard). Never blocks.
-- 1) The app's own Edit ▸ Copy menu item (works while ⌥ is still held).
-- 2) Fallback: once the hotkey's modifiers are released, a real ⌘C
--    (a synthesized ⌘C while ⌥ is physically down arrives as ⌥⌘C).
local function grabSelection(cb)
  local t0 = now()
  local saved = hs.pasteboard.readAllData()
  local before = hs.pasteboard.changeCount()
  local changed = function() return hs.pasteboard.changeCount() ~= before end
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or "?"
  local menuOk = app and app:selectMenuItem({ "Edit", "Copy" })
  pollUntil(changed, menuOk and 400 or 0, function(ok)
    if ok then
      log.i(string.format("selection via Edit>Copy in %s %.0fms", name, now() - t0))
      cb(hs.pasteboard.getContents(), saved); return
    end
    pollUntil(function() return not modifiersHeld() end, 1000, function()
      key({ "cmd" }, "c")
      pollUntil(changed, 450, function(ok2)
        if ok2 then
          log.i(string.format("selection via ⌘C in %s %.0fms", name, now() - t0))
          cb(hs.pasteboard.getContents(), saved)
        else
          log.w(string.format("no selection captured in %s (menu=%s) %.0fms", name, tostring(menuOk), now() - t0))
          cb(nil, saved)
        end
      end)
    end)
  end)
end

-- ── Claude composer ────────────────────────────────────────────────────────────

local axEnabledPid = nil
local function axApp(app)
  local el = hs.axuielement.applicationElement(app)
  if el and axEnabledPid ~= app:pid() then
    pcall(function() el:setAttributeValue("AXManualAccessibility", true) end)
    axEnabledPid = app:pid()
  end
  return el
end

local function focusedComposer(app)
  local a = axApp(app)
  if not a then return nil end
  local f = safeAttr(a, "AXFocusedUIElement")
  if f and safeAttr(f, "AXRole") == "AXTextArea" then return f end
  return nil
end

local function alive(el) return el and safeAttr(el, "AXRole") ~= nil end

-- Every message box in Claude's front window, as { el, box } (box = the card that
-- also holds its Send/dictation buttons). Prefers ones labelled "Prompt".
local function allComposers(app)
  local a = axApp(app)
  local win = a and (safeAttr(a, "AXFocusedWindow") or safeAttr(a, "AXMainWindow"))
  if not win then return {} end
  local prompts, others, visited, chain = {}, {}, 0, {}
  local function walk(el, depth)
    if visited > 4000 or depth > 70 then return end
    visited = visited + 1
    chain[depth] = el
    if safeAttr(el, "AXRole") == "AXTextArea" then
      local entry = { el = el, box = chain[math.max(0, depth - 5)] }
      if safeAttr(el, "AXDescription") == "Prompt" then prompts[#prompts + 1] = entry
      else others[#others + 1] = entry end
      return
    end
    local kids = safeAttr(el, "AXChildren")
    if type(kids) == "table" then for _, k in ipairs(kids) do walk(k, depth + 1) end end
  end
  walk(win, 0)
  return #prompts > 0 and prompts or others
end

-- The message box closest (left-right) to the mouse, i.e. the pane Matt just highlighted in.
local function pickComposer(app)
  local list = allComposers(app)
  if #list <= 1 then return list[1] end
  local mx = hs.mouse.absolutePosition().x
  local best, bestD
  for _, c in ipairs(list) do
    local p, s = safeAttr(c.el, "AXPosition"), safeAttr(c.el, "AXSize")
    local d = math.huge
    if p and s then d = (mx < p.x) and (p.x - mx) or (mx > p.x + s.w and mx - p.x - s.w or 0) end
    if not bestD or d < bestD then best, bestD = c, d end
  end
  return best
end

local function boxOf(el)
  local n = el
  for _ = 1, 5 do
    local p = safeAttr(n, "AXParent")
    if not p then break end
    n = p
  end
  return n
end

-- Is Claude dictation listening? Claude's message box has no dictation button to read,
-- so ask CoreAudio which processes are recording: bin/mic-users --watch prints 1/0
-- when a Claude process starts/stops using the mic. (Something else always holds the
-- mic on this Mac, so plain "mic in use" means nothing.)
local MIC_USERS = os.getenv("HOME") .. "/.hammerspoon/bin/mic-users"
local claudeMic = false

local function watchMic()
  if activeWatchers.quoteMicTask and activeWatchers.quoteMicTask:isRunning() then return end
  local function launch()
    local buf = ""
    activeWatchers.quoteMicTask = hs.task.new(MIC_USERS, function() claudeMic = false end, function(_, out)
      buf = buf .. (out or "")
      for line in buf:gmatch("([01])\n") do
        claudeMic = (line == "1")
        log.i("Claude dictation " .. (claudeMic and "on" or "off"))
      end
      buf = buf:match("[^\n]*$")
      return true
    end, { "--watch", CLAUDE_BUNDLE })
    activeWatchers.quoteMicTask:start()
  end
  if hs.fs.attributes(MIC_USERS) then launch(); return end
  hs.task.new("/usr/bin/swiftc", function(code)
    if code == 0 then launch() else log.e("couldn't build bin/mic-users") end
  end, { "-O", MIC_USERS .. ".swift", "-o", MIC_USERS }):start()
end

local function dictating() return claudeMic end
M.dictating = dictating

local function boxText(el)
  local v = safeAttr(el, "AXValue")
  return type(v) == "string" and trim(v) or ""
end

-- Splits the box into (draft, comment): comment is the last "> quote" block with the
-- marker line under it, through the end; draft is whatever text sits above it.
-- comment is nil when there's no quote + marker at the end of the box.
-- Judged from the text, not the AX element: Claude re-creates the box element.
local function splitComment(text)
  local m = trim(M.marker)
  if m == "" then return text, nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local mi
  for i = #lines, 1, -1 do
    if lines[i]:sub(1, #m) == m then mi = i; break end
    if lines[i]:sub(1, 1) == ">" then return text, nil end -- a quote after the last marker: not ours
  end
  if not mi then return text, nil end
  local j = mi - 1
  while j >= 1 and trim(lines[j]) == "" do j = j - 1 end
  if j < 1 or lines[j]:sub(1, 1) ~= ">" then return text, nil end
  while j >= 1 and (lines[j]:sub(1, 1) == ">" or (trim(lines[j]) == "" and j > 1 and lines[j - 1]:sub(1, 1) == ">")) do
    j = j - 1
  end
  local draft = trim(table.concat(lines, "\n", 1, j))
  return draft, trim(table.concat(lines, "\n", j + 1))
end

-- Does the box end with a quote + comment we put in (with or without a draft above it)?
local function isComment(text)
  local _, comment = splitComment(text)
  return comment ~= nil
end

-- Box text minus a dangling marker (nothing dictated after it).
local function commentText(text)
  local m = trim(M.marker):gsub("%p", "%%%0")
  return trim((text:gsub("%s*" .. m .. "%s*$", "")))
end

-- If dictation is listening, stop it (⌘D) and wait until its text has landed.
-- cb(wasDictating).
local function settle(c, cb)
  if not dictating() then cb(false); return end
  key({ "cmd" }, "d")
  local last, since = nil, now()
  pollUntil(function()
    if dictating() then return false end
    local v = boxText(c.el)
    if v ~= last then last, since = v, now(); return false end
    return now() - since > 400
  end, 5000, function(ok)
    if not ok then log.w("dictation didn't settle in 5 s") end
    cb(true)
  end, 0.1)
end

local function focus(el)
  pcall(function() el:setAttributeValue("AXFocused", true) end)
end

-- Paste text at the caret (clipboard restored by the caller).
local function paste(text)
  hs.pasteboard.setContents(text)
  key({ "cmd" }, "v")
end

local function postReturn()
  for _, down in ipairs({ true, false }) do
    local ev = hs.eventtap.event.newKeyEvent({}, "return", down)
    ev:setProperty(hs.eventtap.event.properties.eventSourceUserData, MAGIC)
    ev:post()
  end
end

-- ── Flows ──────────────────────────────────────────────────────────────────────

-- Move the quote + comment in the box to the queue, leaving any draft text above it
-- in the box (or an empty box), then cb().
local function queueBox(c, cb)
  local draft, comment = splitComment(boxText(c.el))
  if comment == nil then cb(); return end -- already queued (e.g. a second Return while the first ran)
  local text = commentText(comment)
  if text ~= "" then
    table.insert(queue, { text = text })
    saveQueue()
  end
  lastQueued = now()
  focus(c.el)
  after(0.05, function()
    key({ "cmd" }, "a")
    key({}, "delete")
    if draft == "" then after(0.05, cb); return end
    local saved = hs.pasteboard.readAllData()
    after(0.05, function()
      paste(draft)
      after(0.3, function()
        if saved then hs.pasteboard.writeAllData(saved) end
        cb()
      end)
    end)
  end)
end

-- Return on a quote + comment: stop dictation, queue it, clear the box. Holds the input lock.
-- Dictation must stop before the box is cleared: a session still listening re-types
-- its whole transcript when it next stops, which duplicated text under the next quote.
-- If it was on, it's started again (a fresh session) so Matt can keep talking.
local function saveComment(c, release)
  pending = nil
  updateBadge()
  settle(c, function(wasOn)
    queueBox(c, function()
      if wasOn and M.dictate then key({ "cmd" }, "d") end
      release()
    end)
  end)
end

-- Put a quote into Claude's box and start dictation. Called holding the input lock.
local function startComment(quoteText, saved, srcApp, release)
  local function finish(msg)
    after(0.5, function()
      if saved then hs.pasteboard.writeAllData(saved) end
      release()
    end)
    if msg then hs.alert.show(msg) end
  end
  local app = claudeApp()
  if not app then
    hs.pasteboard.setContents(formatQuote(quoteText) .. "\n\n")
    saved = nil
    finish("Claude isn't running: quote copied"); return
  end
  local fromClaude = srcApp and srcApp:bundleID() == CLAUDE_BUNDLE
  if not fromClaude then app:activate() end

  after(fromClaude and 0 or 0.2, function()
    local target = pickComposer(app)
    if not target then
      hs.pasteboard.setContents(formatQuote(quoteText) .. "\n\n")
      saved = nil
      finish("Couldn't find Claude's message box: quote copied, paste with ⌘V"); return
    end

    local function insert()
      focus(target.el)
      after(0.05, function()
        local block = formatQuote(quoteText) .. "\n\n" .. M.marker
        if boxText(target.el) ~= "" then
          -- Something we don't own is in the box (a draft): keep it, add the quote below.
          key({ "cmd" }, "down")
          block = "\n\n" .. block
        end
        paste(block)
        pending = { composer = target }
        updateBadge()
        after(0.15, function()
          if M.dictate and not dictating() then key({ "cmd" }, "d") end -- Claude dictation
          finish()
        end)
      end)
    end

    -- A quote + comment still in the box moves to the queue first.
    pending = nil
    settle(target, function()
      if not isComment(boxText(target.el)) then insert(); return end
      queueBox(target, insert)
    end)
  end)
end

-- Put the queue at the top of Claude's box; optionally send. Called holding the input lock.
local function flushQueue(send, release)
  if #queue == 0 then release(); return end
  local app = claudeApp()
  if not app then hs.alert.show("Claude isn't running"); release(); return end
  app:activate()
  after(0.1, function()
    local el = focusedComposer(app)
    local c = el and { el = el, box = boxOf(el) } or pickComposer(app)
    if not c then
      hs.pasteboard.setContents(queueText())
      hs.alert.show("Couldn't find Claude's message box: quotes copied, paste with ⌘V")
      release(); return
    end
    settle(c, function()
      focus(c.el)
      local saved = hs.pasteboard.readAllData()
      local rest = boxText(c.el)
      local text = queueText() .. (rest ~= "" and "\n\n" or "")
      key({ "cmd" }, "up") -- top of the message
      after(0.05, function()
        paste(text)
        clearQueue()
        pending = (not send) and { composer = c } or nil
        after(0.2, function()
          if send then postReturn() end
          after(0.4, function()
            if saved then hs.pasteboard.writeAllData(saved) end
            release()
          end)
        end)
      end)
    end)
  end)
end

-- ⌘Return / "Send all": queue a quote + comment still in the box, then send everything.
-- Called holding the input lock.
local function sendAll(c, release)
  pending = nil
  if c and isComment(boxText(c.el)) then
    settle(c, function() queueBox(c, function() flushQueue(true, release) end) end)
  else
    flushQueue(true, release)
  end
end

-- The message box to act on from a bar click (Claude keeps focus: canvases don't take it).
local function pendingComposer()
  return pending and alive(pending.composer.el) and pending.composer or nil
end

local function currentComposer()
  local app = claudeApp()
  if not app then return nil end
  local el = focusedComposer(app)
  if el then return { el = el, box = boxOf(el) } end
  return pendingComposer() or pickComposer(app)
end

-- ── Badge ──────────────────────────────────────────────────────────────────────

local function badgeMenu()
  local items = {
    { title = (#queue == 1 and "1 comment" or (#queue .. " comments")) .. " queued: sends with your next Return", disabled = true },
    { title = "-" },
    { title = "Insert into message now (don't send)   ⌥⌘R", fn = function() withInput(function(r) flushQueue(false, r) end) end },
    { title = "Show queued text", fn = function()
        hs.dialog.blockAlert("Queued comments", queueText():sub(1, 1500), "OK")
      end },
    { title = "Remove last", fn = function() table.remove(queue); saveQueue() end },
    { title = "Clear queue", fn = function() clearQueue(); hs.alert.show("Comment queue cleared") end },
  }
  local mb = hs.menubar.new(false)
  mb:setMenu(items)
  mb:popupMenu(hs.mouse.absolutePosition())
  hs.timer.doAfter(1, function() mb:delete() end)
end

-- Anchored to Claude's window (not a screen corner), so it's exempt in hud_slots.json.
-- [ ❝ N queued ] [ Queue ⏎ ] [ Send all ⌘⏎ ]. Fixed widths, so nothing shifts when the count changes.
local PILL_W, QUEUE_W, SEND_W = 96, 84, 104

local function onBarClick(id)
  if id == "pill" then badgeMenu()
  elseif id == "queue" then
    if not pending then return end
    withInput(function(r)
      local c = currentComposer()
      if c and isComment(boxText(c.el)) then saveComment(c, r) else r() end
    end)
  elseif id == "send" then
    withInput(function(r) sendAll(currentComposer(), r) end)
  end
end

updateBadge = function(hidden)
  local front = hs.application.frontmostApplication()
  local claudeFront = hidden or (front and front:bundleID() == CLAUDE_BUNDLE)
  if (#queue == 0 and not pending) or not claudeFront then
    if activeWatchers.quoteBadge then activeWatchers.quoteBadge:delete(); activeWatchers.quoteBadge = nil end
    return
  end
  local h, gap, size = T("bar.height"), T("bar.gap"), T("bar.text")
  local w = PILL_W + QUEUE_W + SEND_W + gap * 2
  local frame
  local win = (not hidden) and (front:focusedWindow() or front:mainWindow())
  if win then
    local f = win:frame()
    frame = { x = f.x + f.w - w - T("bar.right"), y = f.y + f.h - h - T("bar.bottom"), w = w, h = h }
  else
    local s = hs.screen.mainScreen():frame()
    frame = { x = s.x + s.w - w - 24, y = s.y + s.h - h - 24, w = w, h = h }
  end

  local c = activeWatchers.quoteBadge
  if not c then
    c = hs.canvas.new(frame)
    c:level(hs.canvas.windowLevels.floating)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c:canvasMouseEvents(false, true)
    c:mouseCallback(function(_, msg, id) if msg == "mouseUp" then onBarClick(id) end end)
    activeWatchers.quoteBadge = c
  else
    c:frame(frame)
  end

  local accent, alpha = T("look.accent"), T("look.alpha")
  local r = { xRadius = h / 2, yRadius = h / 2 }
  local pill = require("modules.claude_pill")
  local function label(text, color) return pill.label(text, size, color) end
  local ty = (h - size * 1.3) / 2
  local x2, x3 = PILL_W + gap, PILL_W + QUEUE_W + gap * 2
  local queueAlpha = pending and alpha or T("look.dimAlpha")
  -- count pill (shared look with thread_queue.lua): click for the menu
  local els = pill.elements{ id = "pill", w = PILL_W, h = h, size = size, accent = accent, alpha = alpha,
    text = "❝ " .. #queue .. " queued" }
  for _, el in ipairs{
    -- Queue: the default (Return) while a quote + comment is in the box
    { id = "queue", type = "rectangle", action = "fill", fillColor = { white = 1, alpha = queueAlpha },
      frame = { x = x2, y = 0, w = QUEUE_W, h = h }, roundedRectRadii = r, trackMouseUp = true },
    { type = "rectangle", action = "stroke", strokeColor = { hex = accent, alpha = queueAlpha }, strokeWidth = T("look.queueBorderWidth"),
      frame = { x = x2 + 1, y = 1, w = QUEUE_W - 2, h = h - 2 }, roundedRectRadii = r },
    { type = "text", frame = { x = x2, y = ty, w = QUEUE_W, h = h },
      text = label("Queue ⏎", { hex = accent, alpha = pending and 1 or queueAlpha }) },
    -- Send all: ⌘Return
    { id = "send", type = "rectangle", action = "fill", fillColor = { white = 1, alpha = alpha },
      frame = { x = x3, y = 0, w = SEND_W, h = h }, roundedRectRadii = r, trackMouseUp = true },
    { type = "rectangle", action = "stroke", strokeColor = { white = T("look.sendBorderWhite"), alpha = alpha }, strokeWidth = 1,
      frame = { x = x3 + 0.5, y = 0.5, w = SEND_W - 1, h = h - 1 }, roundedRectRadii = r },
    { type = "text", frame = { x = x3, y = ty, w = SEND_W, h = h },
      text = label(pending and "Send all ⌘⏎" or "Send all ⏎", { white = T("look.sendTextWhite") }) },
  } do els[#els + 1] = el end
  c:replaceElements(els)
  if hidden then return c end
  c:show()
end

-- ── Entry points ────────────────────────────────────────────────────────────────

local function run(withComment)
  if hs.eventtap.isSecureInputEnabled() then
    hs.alert.show("Secure input is on: can't read selection"); return
  end
  local srcApp = hs.application.frontmostApplication()
  withInput(function(release)
    grabSelection(function(text, saved)
      if not text or trim(text) == "" then
        if saved then hs.pasteboard.writeAllData(saved) end
        hs.alert.show("Highlight some text first")
        release(); return
      end
      if not withComment then
        table.insert(queue, { quote = text, comment = "" })
        saveQueue()
        if saved then hs.pasteboard.writeAllData(saved) end
        release(); return
      end
      -- ⌘A/⌘V/⌘D need the hotkey's ⌥ released, else they arrive as ⌥⌘…
      pollUntil(function() return not modifiersHeld() end, 1500, function()
        startComment(text, saved, srcApp, release)
      end)
    end)
  end)
end

local function returnTap(e)
  if e:getProperty(hs.eventtap.event.properties.eventSourceUserData) == MAGIC then return false end
  local kc = e:getKeyCode()
  if kc ~= RETURN and kc ~= PADENTER then return false end
  if #queue == 0 and not pending then return false end
  local f = e:getFlags()
  if f.shift or f.alt or f.ctrl or f.fn then return false end
  if e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 1 then return false end
  local app = hs.application.frontmostApplication()
  if not app or app:bundleID() ~= CLAUDE_BUNDLE then return false end
  local composer = focusedComposer(app)
  if not composer then return false end
  local val = safeAttr(composer, "AXValue")
  val = type(val) == "string" and trim(val) or ""
  if f.cmd then -- ⌘Return: send the queue and any quote + comment in the box
    if val:match("^/") or (#queue == 0 and not isComment(val)) then return false end
    local c = { el = composer, box = boxOf(composer) }
    hs.timer.doAfter(0, function() withInput(function(r) sendAll(c, r) end) end)
    return true
  end
  if isComment(val) then -- save the comment to the queue, never send
    lastQueued = now()
    local c = { el = composer, box = boxOf(composer) }
    hs.timer.doAfter(0, function() withInput(function(r) saveComment(c, r) end) end)
    return true
  end
  pending = nil
  updateBadge()
  if #queue == 0 or val:match("^/") then return false end
  if now() - lastQueued < T("send.guard") * 1000 then -- a double-tapped Return: don't send
    log.i("Return right after queueing: ignored")
    return true
  end
  hs.timer.doAfter(0, function() withInput(function(r) flushQueue(true, r) end) end)
  return true
end

function M.start()
  M.stop()
  activeWatchers.quoteCommentHotkey = hs.hotkey.bind({ "alt" }, "R", function() run(true) end)
  activeWatchers.quoteOnlyHotkey = hs.hotkey.bind({ "alt", "shift" }, "R", function() run(false) end)
  activeWatchers.quoteFlushHotkey = hs.hotkey.bind({ "alt", "cmd" }, "R", function()
    withInput(function(r)
      pollUntil(function() return not modifiersHeld() end, 1500, function() flushQueue(false, r) end)
    end)
  end)
  activeWatchers.quoteReturnTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, returnTap)
  activeWatchers.quoteReturnTap:start()
  watchMic()
  -- Keep the badge glued to Claude's window and hidden when Claude isn't in front.
  -- Claude's own windows only: an hs.window.filter (even for one app) makes
  -- Hammerspoon scan every running app on each reload, ~2 s with typing held up.
  local function watchClaudeWindows()
    if activeWatchers.quoteWinWatcher then activeWatchers.quoteWinWatcher:stop(); activeWatchers.quoteWinWatcher = nil end
    local app = claudeApp()
    if not app then return end
    activeWatchers.quoteWinWatcher = app:newWatcher(function() updateBadge() end)
    activeWatchers.quoteWinWatcher:start({ hs.uielement.watcher.windowMoved, hs.uielement.watcher.windowResized,
      hs.uielement.watcher.focusedWindowChanged })
  end
  activeWatchers.quoteAppWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.activated or event == hs.application.watcher.deactivated then
      updateBadge()
    elseif event == hs.application.watcher.launched and app and app:bundleID() == CLAUDE_BUNDLE then
      watchClaudeWindows()
    end
  end)
  activeWatchers.quoteAppWatcher:start()
  watchClaudeWindows()
  updateBadge()
end

function M.stop()
  for _, k in ipairs({ "quoteCommentHotkey", "quoteOnlyHotkey", "quoteFlushHotkey" }) do
    if activeWatchers[k] then activeWatchers[k]:delete(); activeWatchers[k] = nil end
  end
  if activeWatchers.quoteReturnTap then activeWatchers.quoteReturnTap:stop(); activeWatchers.quoteReturnTap = nil end
  if activeWatchers.quoteMicTask then activeWatchers.quoteMicTask:terminate(); activeWatchers.quoteMicTask = nil end
  if activeWatchers.quoteBadge then activeWatchers.quoteBadge:delete(); activeWatchers.quoteBadge = nil end
  if activeWatchers.quoteAppWatcher then activeWatchers.quoteAppWatcher:stop(); activeWatchers.quoteAppWatcher = nil end
  if activeWatchers.quoteWinWatcher then activeWatchers.quoteWinWatcher:stop(); activeWatchers.quoteWinWatcher = nil end
end

-- For testing from `hs -c` (each needs the input lock: claude-control ask first).
M._startComment = function(text, release) startComment(text, nil, claudeApp(), release or function() end) end
M._flush = function(send, release) flushQueue(send, release or function() end) end
-- Draws the bar off screen and returns it as an image (pendingFlag = quote in the box).
M._previewBar = function(pendingFlag)
  local saved, savedC = pending, activeWatchers.quoteBadge
  pending = pendingFlag and { composer = {} } or nil
  activeWatchers.quoteBadge = nil
  local c = updateBadge(true)
  local img = c and c:imageFromCanvas()
  if c then c:delete() end
  pending, activeWatchers.quoteBadge = saved, savedC
  return img
end
M._sendAll = function(release) sendAll(currentComposer(), release or function() end) end
M._state = function() return { queued = #queue, pending = pending ~= nil, text = queueText(), dictating = claudeMic } end
M._formatQuote, M._itemText, M._isComment, M._commentText = formatQuote, itemText, isComment, commentText
M._spaceComment, M._splitComment = spaceComment, splitComment

return M
