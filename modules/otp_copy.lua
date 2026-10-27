-- ~/.hammerspoon/modules/otp_copy.lua
-- 2FA codes from Messages and Mail land on the clipboard by themselves.
--
--   • Messages: watches ~/Library/Messages (chat.db) and reads new incoming rows
--     with /usr/bin/sqlite3 (async, read-only). Newer macOS keeps the text only in
--     attributedBody, so that blob is decoded too.
--   • Mail: watches ~/Library/Mail for new .emlx / .partial.emlx files and reads
--     subject + body.
--   • Both need Full Disk Access for Hammerspoon (System Settings > Privacy &
--     Security > Full Disk Access). Without it the module alerts once and idles.
--   • The code is copied as "concealed" (org.nspasteboard.ConcealedType), so
--     clipboard managers that honour it (Maccy, Pastebot, Raycast…) don't keep it,
--     and it's wiped from the clipboard after CLEAR_AFTER seconds (the previous
--     clipboard text comes back) unless you've copied something else since.
--   • Google's "G-123456" codes copy as "123456" (Google's own field rejects G-).
--   • A small pill shows the code just below the focused text field (middle of the
--     screen if the field can't be read). It goes away once the code is pasted
--     (⌘V, or the field now holds the code), when clicked, or after pill.seconds.
--
-- Pure parts (extract, decodeAttributedBody, parseEmlx) need no hs.*:
--   lua tests/otp_copy_test.lua

local M = {
  id = "otp_copy",
  name = "2FA Code Auto-Copy (Messages & Mail)"
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local HOME = os.getenv("HOME")
local MESSAGES_DIR = HOME .. "/Library/Messages"
local CHAT_DB = MESSAGES_DIR .. "/chat.db"
local MAIL_DIR = HOME .. "/Library/Mail"

local CFG = {
  maxAge = 600,        -- ignore messages/emails older than this (s): history syncs, backfills
  dedupe = 120,        -- same code again within this window (s) is ignored (SMS + email copies)
  clearAfter = 120,    -- wipe the code from the clipboard after this many seconds
  maxDistance = 100,   -- code must sit within this many bytes of a keyword
  emlxMaxBytes = 400000,
}
M.CFG = CFG

-- ── Code extraction (pure) ───────────────────────────────────────────────────

M.KEYWORDS = {
  "verification code", "security code", "login code", "sign-in code", "access code",
  "one-time", "one time", "passcode", "otp", "2fa", "two-factor", "authentication code",
  "confirmation code", "verify", "verification", "captcha", "code", "pin",
  "验证码", "动态密码", "验证", "代码", "인증", "認証", "código", "codice", "code de",
}

-- Bytes that glue a token into a URL, email, file name or ID: such tokens aren't codes.
local GLUE_BEFORE = "[/=&?@_%%#%.]"
local GLUE_AFTER = "[/=&?@_%%#]"

local function keywordSpans(text)
  local lower = text:lower()
  local spans = {}
  for _, kw in ipairs(M.KEYWORDS) do
    local from = 1
    while true do
      local s, e = lower:find(kw, from, true)
      if not s then break end
      -- ASCII keywords must be whole words ("pin" not in "shopping", "otp" not in "otpauth")
      local before, after = lower:sub(s - 1, s - 1), lower:sub(e + 1, e + 1)
      local ascii = not kw:find("[\128-\255]")
      if not ascii or (not before:match("[%a]") and not after:match("[%a]")) then
        spans[#spans + 1] = { s, e }
      end
      from = e + 1
    end
  end
  return spans
end

-- Candidate codes: { code, start, numeric }.
local function candidates(text)
  local out = {}
  for s, token, e in text:gmatch("()([%w%-]+)()") do
    local before, after = text:sub(s - 1, s - 1), text:sub(e, e)
    if not before:match(GLUE_BEFORE) and not after:match(GLUE_AFTER) then
      local digits = token:match("^%u%-(%d+)$")  -- Google: G-123456 → 123456
      if digits and #digits >= 4 and #digits <= 8 then
        out[#out + 1] = { code = digits, s = s + 2, numeric = true }
      elseif #token >= 4 and #token <= 8 and token:find("%d")
          and select(2, token:gsub("%-", "")) <= 1
          and not token:match("^%-") and not token:match("%-$") then
        if token:match("^%d+$") then
          out[#out + 1] = { code = token, s = s, numeric = true }
        elseif token:match("^[%u%d%-]+$") then
          -- Letters allowed only in upper case (ABCD123, RKJ-YP6, 12345X);
          -- mixed-case strings are link slugs and IDs, not codes.
          out[#out + 1] = { code = token, s = s, numeric = false }
        end
      end
    end
  end
  return out
end

local function distance(c, span)
  local cs, ce = c.s, c.s + #c.code - 1
  if cs > span[2] then return cs - span[2] end
  if ce < span[1] then return span[1] - ce end
  return 0
end

-- The code in `text`, or nil. Needs a keyword; picks the candidate nearest any
-- keyword, preferring all-digit codes over letter codes.
function M.extract(text)
  if type(text) ~= "string" or text == "" then return nil end
  local spans = keywordSpans(text)
  if #spans == 0 then return nil end
  local best, bestScore
  for _, c in ipairs(candidates(text)) do
    local d = math.huge
    for _, span in ipairs(spans) do d = math.min(d, distance(c, span)) end
    if d <= CFG.maxDistance then
      local score = d + (c.numeric and 0 or 1000)
      if not bestScore or score < bestScore then best, bestScore = c.code, score end
    end
  end
  return best
end

-- ── Messages attributedBody (pure) ───────────────────────────────────────────
-- typedstream blob: "...NSString" 0x01 0x94 0x84 0x01 '+' <len> <utf8 bytes>.
-- <len> is one byte below 0x80, or 0x81 + 2 bytes / 0x82 + 4 bytes little-endian.

function M.hexToBytes(hex)
  return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

function M.decodeAttributedBody(blob)
  if type(blob) ~= "string" or blob == "" then return nil end
  local at = blob:find("NSString", 1, true)
  if not at then return nil end
  local plus = blob:find("+", at + 8, true)
  if not plus or plus > at + 16 then return nil end
  local i = plus + 1
  local b = blob:byte(i)
  if not b then return nil end
  local len
  if b < 0x80 then
    len, i = b, i + 1
  elseif b == 0x81 then
    len, i = blob:byte(i + 1) + blob:byte(i + 2) * 256, i + 3
  elseif b == 0x82 then
    len = blob:byte(i + 1) + blob:byte(i + 2) * 256 + blob:byte(i + 3) * 65536 + blob:byte(i + 4) * 16777216
    i = i + 5
  else
    return nil
  end
  return blob:sub(i, i + len - 1)
end

-- ── Mail .emlx (pure) ────────────────────────────────────────────────────────

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64IDX = {}
for i = 1, 64 do B64IDX[B64:byte(i)] = i - 1 end

function M.base64Decode(s)
  s = s:gsub("[^%w%+/]", "")
  local out, bits, n = {}, 0, 0
  for i = 1, #s do
    bits = bits * 64 + B64IDX[s:byte(i)]
    n = n + 6
    if n >= 8 then
      n = n - 8
      local byte = math.floor(bits / 2 ^ n) % 256
      out[#out + 1] = string.char(byte)
      bits = bits % 2 ^ n
    end
  end
  return table.concat(out)
end

function M.qpDecode(s)
  s = s:gsub("=\r?\n", "")
  return (s:gsub("=(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- "=?UTF-8?B?...?=" / "=?UTF-8?Q?...?=" in headers.
local function decodeWords(s)
  return (s:gsub("=%?[^?]+%?([BbQq])%?([^?]*)%?=", function(enc, data)
    if enc:upper() == "B" then return M.base64Decode(data) end
    return M.qpDecode((data:gsub("_", " ")))
  end))
end

local function splitHeaders(part)
  local head, body = part:match("^(.-)\r?\n\r?\n(.*)$")
  if not head then return {}, part end
  head = head:gsub("\r?\n[ \t]+", " ")
  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local k, v = line:match("^([%w%-]+):%s*(.*)$")
    if k then headers[k:lower()] = v end
  end
  return headers, body
end

local function stripHtml(s)
  s = s:gsub("<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>", " ")
  s = s:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>", " ")
  s = s:gsub("<[^>]*>", " ")
  s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&#%d+;", " ")
  return s
end

-- Collects { plain = {...}, html = {...} } text parts of a MIME entity.
local function walk(part, acc, depth)
  if depth > 8 then return end
  local headers, body = splitHeaders(part)
  local ctype = (headers["content-type"] or "text/plain"):lower()
  local boundary = (headers["content-type"] or ""):match('[Bb][Oo][Uu][Nn][Dd][Aa][Rr][Yy]="?([^";]+)"?')
  if ctype:find("^multipart/") and boundary then
    local marker = "--" .. boundary
    local pos = 1
    local chunks = {}
    while true do
      local s, e = body:find(marker, pos, true)
      if not s then break end
      chunks[#chunks + 1] = e + 1
      pos = e + 1
    end
    for i = 1, #chunks - 1 do
      local chunk = body:sub(chunks[i], body:find(marker, chunks[i], true) - 1)
      chunk = chunk:gsub("^\r?\n", "")
      walk(chunk, acc, depth + 1)
    end
    return
  end
  if not ctype:find("^text/") then return end
  local enc = (headers["content-transfer-encoding"] or ""):lower()
  if enc:find("base64") then body = M.base64Decode(body)
  elseif enc:find("quoted%-printable") then body = M.qpDecode(body) end
  if ctype:find("^text/html") then acc.html[#acc.html + 1] = stripHtml(body)
  else acc.plain[#acc.plain + 1] = body end
end

-- { text = subject .. body, received = epoch or nil } from raw .emlx bytes.
function M.parseEmlx(raw)
  if type(raw) ~= "string" then return nil end
  local count, rest = raw:match("^%s*(%d+)%s*\r?\n(.*)$")
  local msg = count and rest:sub(1, tonumber(count)) or raw
  local plist = count and rest:sub(tonumber(count) + 1) or ""
  local received = tonumber(plist:match("<key>date%-received</key>%s*<[%a]+>([%d%.]+)<"))
  local headers = splitHeaders(msg)
  local acc = { plain = {}, html = {} }
  walk(msg, acc, 0)
  local body = #acc.plain > 0 and table.concat(acc.plain, "\n") or table.concat(acc.html, "\n")
  local subject = decodeWords(headers.subject or "")
  return { text = subject .. "\n" .. body, subject = subject, received = received }
end

-- ── Clipboard + pill (hs) ────────────────────────────────────────────────────

-- Where the pill goes (pure): just below the field, above it if there's no room
-- below, kept on screen; no field → the middle of the screen. Frames are
-- {x, y, w, h} in Hammerspoon's top-left-origin coordinates.
function M.placePill(field, screen, w, h, gap)
  if not field then
    return { x = screen.x + (screen.w - w) / 2, y = screen.y + (screen.h - h) / 2, w = w, h = h }
  end
  local y = field.y + field.h + gap
  if y + h > screen.y + screen.h then y = field.y - gap - h end
  y = math.max(screen.y, math.min(y, screen.y + screen.h - h))
  local x = math.max(screen.x, math.min(field.x, screen.x + screen.w - w))
  return { x = x, y = y, w = w, h = h }
end

-- Roles that take typed text; anything else (a whole web page, a window) means
-- we don't know where the field is.
local TEXT_ROLES = { AXTextField = true, AXTextArea = true, AXComboBox = true, AXSearchField = true }

local recent = {}       -- code → epoch last copied
local clearTimer, pill, pillTimer, pasteTap, pastePoll
local savedPrevious, copiedStamp  -- clipboard before the first pending code, and our write's changeCount

-- Feel knobs: ~/.hammerspoon/tweaks/otp_copy.json, or the Tweaks panel (⌃⌥⌘T).
-- Opened on first use so the pure tests can load this file without hs.*.
local tweaksHandle
local function T(key)
  tweaksHandle = tweaksHandle or require("modules.tweaks").open{
    app = "2FA Code Auto-Copy",
    file = require("modules.tweaks").dir .. "/otp_copy.json",
    knobs = {
    ["look.pillWidth"] = { 230, min = 160, max = 360, step = 2, note = "Pill width in points" },
    ["look.cornerRadius"] = { 12, min = 0, max = 26, step = 1, note = "Pill corner radius in points" },
    ["look.fillOpacity"] = { 0.96, min = 0.5, max = 1, step = 0.02, note = "Pill background opacity, 0 to 1" },
    ["look.borderWidth"] = { 1.5, min = 0, max = 4, step = 0.25, note = "Pill border thickness in points" },
    ["look.codeSize"] = { 19, min = 12, max = 32, step = 1, note = "Font size of the code in points" },
    ["look.subtitleSize"] = { 10.5, min = 8, max = 16, step = 0.5, note = "Font size of the 'Copied from' line in points" },
      ["pill.seconds"] = { 12, min = 3, max = 60, step = 1, note = "Seconds the code pill stays up" },
      ["pill.gap"] = { 8, min = 0, max = 40, step = 1, note = "Gap between the text field and the pill (px)" },
      ["paste.delay"] = { 0.3, min = 0, max = 2, step = 0.05, note = "Seconds after ⌘V before the pill fades" },
    },
  }
  return tweaksHandle(key)
end

local function focusedElement()
  local ok, el = pcall(function()
    local sys = hs.axuielement.systemWideElement()
    if sys.setTimeout then sys:setTimeout(0.3) end
    return sys:attributeValue("AXFocusedUIElement")
  end)
  return ok and el or nil
end

-- Frame of the focused text field, or nil if it can't be read.
local function focusedFieldFrame()
  local el = focusedElement()
  if not el then return nil end
  local ok, frame = pcall(function()
    if not TEXT_ROLES[el:attributeValue("AXRole") or ""] then return nil end
    local f = el:attributeValue("AXFrame")
    if not f then
      local p, s = el:attributeValue("AXPosition"), el:attributeValue("AXSize")
      if p and s then f = { x = p.x, y = p.y, w = s.w, h = s.h } end
    end
    return f
  end)
  if not ok or not frame or not frame.w or frame.w <= 0 or frame.h <= 0 then return nil end
  return frame
end

local function stopPasteWatch()
  if pasteTap then pasteTap:stop(); pasteTap = nil end
  if pastePoll then pastePoll:stop(); pastePoll = nil end
end

local function hidePill()
  stopPasteWatch()
  if pillTimer then pillTimer:stop(); pillTimer = nil end
  if pill then
    local c = pill
    pill = nil
    c:hide(0.3)
    hs.timer.doAfter(0.4, function() c:delete() end)
  end
end

local function showPill(code, source)
  hidePill()
  local dark = hs.host.interfaceStyle() == "Dark"
  local w, h = T("look.pillWidth"), 52
  local field = focusedFieldFrame()
  local screen = (field and hs.screen.find(hs.geometry.rect(field.x, field.y, field.w, field.h)))
    or (hs.window.focusedWindow() and hs.window.focusedWindow():screen()) or hs.screen.mainScreen()
  local sf = screen:fullFrame()
  local rect = M.placePill(field, { x = sf.x, y = sf.y, w = sf.w, h = sf.h }, w, h, T("pill.gap"))
  local c = hs.canvas.new(rect)
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  c:clickActivating(false)
  c:appendElements(
    { type = "rectangle", action = "fill", trackMouseDown = true,
      roundedRectRadii = { xRadius = T("look.cornerRadius"), yRadius = T("look.cornerRadius") },
      fillColor = dark and { hex = "#1F3A27", alpha = T("look.fillOpacity") } or { hex = "#E6F4E9", alpha = T("look.fillOpacity") },
      strokeColor = dark and { hex = "#3E8B55", alpha = 0.8 } or { hex = "#5DB36F", alpha = 0.7 },
      strokeWidth = T("look.borderWidth") },
    { type = "text", text = code, frame = { x = 14, y = 6, w = w - 28, h = 24 },
      textSize = T("look.codeSize"), textFont = "Menlo-Bold",
      textColor = dark and { hex = "#BFE6C8" } or { hex = "#1E4D2B" } },
    { type = "text", text = "Copied from " .. source .. "  ·  ⌘V to paste",
      frame = { x = 14, y = 31, w = w - 28, h = 16 }, textSize = T("look.subtitleSize"),
      textColor = dark and { hex = "#9CC9A7", alpha = 0.9 } or { hex = "#3F6B4B", alpha = 0.9 } }
  )
  c:mouseCallback(function() hidePill() end)
  c:show(0.15)
  pill = c
  pillTimer = hs.timer.doAfter(T("pill.seconds"), hidePill)

  -- Gone once the code is pasted: ⌘V while the clipboard still holds it, or the
  -- focused field's text now contains it (menu Paste, autofill, typed by hand).
  local function hideThis() if pill == c then hidePill() end end
  local V = hs.keycodes.map.v
  pasteTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local f = e:getFlags()
    if e:getKeyCode() == V and f.cmd and not (f.alt or f.ctrl or f.shift)
        and hs.pasteboard.changeCount() == copiedStamp then
      hs.timer.doAfter(T("paste.delay"), hideThis)
    end
    return false
  end):start()
  pastePoll = hs.timer.doEvery(0.5, function()
    local el = focusedElement()
    local ok, value = pcall(function() return el and el:attributeValue("AXValue") end)
    if ok and type(value) == "string" and value:find(code, 1, true) then hideThis() end
  end)
end

-- For checks from `hs -c`: where the pill is, and whether the paste watch runs.
function M.pillState()
  if not pill then return nil end
  return { frame = pill:frame(), tap = pasteTap ~= nil and pasteTap:isEnabled(), poll = pastePoll ~= nil }
end

local function writeConcealed(code)
  hs.pasteboard.writeAllData({
    ["public.utf8-plain-text"] = code,
    ["org.nspasteboard.ConcealedType"] = "",
    ["org.nspasteboard.TransientType"] = "",
  })
end

function M.deliver(code, source)
  local now = os.time()
  for k, t in pairs(recent) do if now - t > CFG.dedupe then recent[k] = nil end end
  if recent[code] then return end
  recent[code] = now

  local function copy(release)
    -- A second code before the first was wiped: keep the clipboard from before both.
    if not (clearTimer and hs.pasteboard.changeCount() == copiedStamp) then
      savedPrevious = hs.pasteboard.getContents()
    end
    local previous = savedPrevious
    writeConcealed(code)
    local stamp = hs.pasteboard.changeCount()
    copiedStamp = stamp
    if release then release() end
    print("🔐 otp_copy: copied a code from " .. source)
    showPill(code, source)
    if clearTimer then clearTimer:stop() end
    clearTimer = hs.timer.doAfter(CFG.clearAfter, function()
      clearTimer = nil
      if hs.pasteboard.changeCount() ~= stamp then return end -- copied something else since
      if previous and previous ~= code then hs.pasteboard.setContents(previous)
      else hs.pasteboard.clearContents() end
      savedPrevious = nil
    end)
  end

  -- Clipboard writes from automations queue behind agents holding the Mac.
  if _G.claudeControl and _G.claudeControl.withInput then
    _G.claudeControl.withInput("otp_copy", copy)
  else
    copy()
  end
end

-- ── Messages watcher ─────────────────────────────────────────────────────────

local lastRowId
local queryRunning, queryAgain = false, false

-- Messages' date column: nanoseconds since 2001-01-01.
local APPLE_EPOCH = 978307200

local function runQuery(sql, cb)
  local t = hs.task.new("/usr/bin/sqlite3", function(code, out, err)
    if code ~= 0 then print("otp_copy sqlite3: " .. tostring(err)); cb(nil) return end
    local ok, rows = pcall(hs.json.decode, (out ~= "" and out) or "[]")
    cb(ok and rows or nil)
  end, { "-readonly", "-json", CHAT_DB, sql })
  t:start()
  return t
end

local function checkMessages()
  if queryRunning then queryAgain = true return end
  if not lastRowId then return end
  queryRunning = true
  local minDate = string.format("%.0f", (os.time() - CFG.maxAge - APPLE_EPOCH) * 1e9)
  local sql = string.format(
    "SELECT ROWID AS id, text, hex(attributedBody) AS ab FROM message " ..
    "WHERE ROWID > %d AND is_from_me = 0 AND date > %s ORDER BY ROWID", lastRowId, minDate)
  activeWatchers.otpCopyTask = runQuery(sql, function(rows)
    queryRunning = false
    for _, r in ipairs(rows or {}) do
      lastRowId = math.max(lastRowId, tonumber(r.id) or 0)
      local text = r.text
      if (not text or text == "") and r.ab and r.ab ~= "" then
        text = M.decodeAttributedBody(M.hexToBytes(r.ab))
      end
      local code = M.extract(text)
      if code then M.deliver(code, "Messages") end
    end
    if queryAgain then queryAgain = false; checkMessages() end
  end)
end

local function startMessages()
  activeWatchers.otpCopyTask = runQuery("SELECT IFNULL(MAX(ROWID), 0) AS id FROM message", function(rows)
    if not rows or not rows[1] then return end
    lastRowId = tonumber(rows[1].id) or 0
  end)
  local debounce
  activeWatchers.otpCopyMessagesWatcher = hs.pathwatcher.new(MESSAGES_DIR, function(paths)
    for _, p in ipairs(paths) do
      if p:find("chat%.db") then
        if debounce then debounce:stop() end
        debounce = hs.timer.doAfter(0.4, checkMessages)
        activeWatchers.otpCopyDebounce = debounce
        return
      end
    end
  end):start()
end

-- ── Mail watcher ─────────────────────────────────────────────────────────────

local seenMail = {}

local function checkEmlx(path)
  if seenMail[path] then return end
  local attr = hs.fs.attributes(path)
  if not attr or attr.mode ~= "file" then return end
  if os.time() - (attr.creation or attr.modification or 0) > CFG.maxAge then return end
  seenMail[path] = true
  local f = io.open(path, "rb")
  if not f then return end
  local raw = f:read(CFG.emlxMaxBytes)
  f:close()
  local ok, mail = pcall(M.parseEmlx, raw)
  if not ok or not mail then return end
  if mail.received and os.time() - mail.received > CFG.maxAge then return end
  local code = M.extract(mail.text)
  if code then M.deliver(code, "Mail") end
end

local function startMail()
  activeWatchers.otpCopyMailWatcher = hs.pathwatcher.new(MAIL_DIR, function(paths)
    for _, p in ipairs(paths) do
      -- .partial.emlx = headers + text parts, with images/attachments stored apart
      -- (most HTML mail, e.g. Kijiji); it holds the code just the same.
      if p:find("%.emlx$") then
        -- let Mail finish writing before reading
        hs.timer.doAfter(0.5, function() checkEmlx(p) end)
      end
    end
  end):start()
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

local function hasFullDiskAccess()
  local f = io.open(CHAT_DB, "rb")
  if f then f:close() return true end
  return false
end

function M.start()
  M.stop()
  T("pill.seconds") -- seeds the tweaks file so the knobs show in the panel now
  if not hasFullDiskAccess() then
    print("⚠️ otp_copy: Hammerspoon has no Full Disk Access, so it can't read Messages or Mail")
    hs.alert.show("2FA Code Auto-Copy needs Full Disk Access for Hammerspoon\n" ..
      "System Settings › Privacy & Security › Full Disk Access", 6)
    return
  end
  startMessages()
  startMail()
end

function M.stop()
  for _, k in ipairs({ "otpCopyMessagesWatcher", "otpCopyMailWatcher", "otpCopyDebounce", "otpCopyTask" }) do
    local w = activeWatchers[k]
    if w then
      if w.terminate and w:isRunning() then w:terminate() elseif w.stop then w:stop() end
      activeWatchers[k] = nil
    end
  end
  if clearTimer then clearTimer:stop(); clearTimer = nil end
  hidePill()
  lastRowId, queryRunning, queryAgain = nil, false, false
end

return M
