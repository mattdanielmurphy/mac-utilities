-- modules/claude_read_aloud.lua
-- Presses Claude's own "Read aloud" button on each queued reply, oldest first, then starts
-- Claude's own dictation (⌘D) when the queue is done, so Matt can answer by voice.
-- The mod writes one JSON per reply to ~/.hammerspoon/tmp/read_aloud_queue/ ({key, cut, chars,
-- session}); a reply's button is found by its opening words, so it works in any thread.
-- cut = spoken characters before the hidden Actions line: reading is stopped there by time.
--
-- Driven by the ai-os read-aloud mod (mods/read-aloud):
--   hs -c 'require("modules.claude_read_aloud").replyDone()'  -- a Coordinator reply finished
--   hs -c 'require("modules.claude_read_aloud").cancel()'     -- Matt typed or sent something
--
-- Flow: Claude in front with the Coordinator on screen → read now. Otherwise a soft sound plays
-- and the reply waits until Matt is back in Claude looking at the Coordinator. The press goes
-- through the accessibility tree (no mouse or keys) and takes the claude-control queue.

local ax = require("hs.axuielement")
local tweaks = require("modules.tweaks")
local cc = require("modules.claude_control")

local M = {}

local T = tweaks.open{
  app = "Claude read aloud",
  file = tweaks.dir .. "/claude_read_aloud.json",
  knobs = {
    ["speech.cps"] = { 15, min = 8, max = 25, step = 0.5, note = "Characters per second Claude's voice reads (times the stop before the Actions line)" },
    ["speech.pad"] = { 0.6, min = 0, max = 3, step = 0.1, note = "Seconds of grace after that estimate before stopping" },
    ["queue.maxAge"] = { 12, min = 1, max = 72, step = 1, note = "Hours a queued reply waits before it's dropped" },
    ["away.sound"] = { "Tink", note = "System sound when a reply lands while you're elsewhere (blank = none)" },
    ["away.volume"] = { 0.4, min = 0, max = 1, step = 0.05, note = "Volume of that sound" },
    ["start.poll"] = { 0.15, min = 0.05, max = 1, step = 0.05, note = "Seconds between checks for the Read aloud button after a reply ends" },
    ["start.timeout"] = { 10, min = 3, max = 30, step = 1, note = "Seconds to wait for Claude's voice to start after a press before trying again" },
    ["start.window"] = { 4, min = 1, max = 15, step = 0.5, note = "Seconds of fast checking before slowing down" },
    ["return.delay"] = { 0.2, min = 0, max = 3, step = 0.1, note = "Seconds after switching back before reading starts" },
    ["dictate.after"] = { true, note = "Start dictation when reading ends" },
    ["duck.fadeDown"] = { 1.2, min = 0, max = 5, step = 0.1, note = "Seconds the music takes to fade down when Claude starts reading" },
    ["duck.fadeUp"] = { 2, min = 0, max = 6, step = 0.1, note = "Seconds the music takes to come back up after reading" },
    ["duck.level"] = { 0.55, min = 0, max = 1, step = 0.05, note = "Music/Spotify volume while Claude reads, as a share of where it was (1 = no ducking)" },
    ["dictate.delay"] = { 0.4, min = 0, max = 3, step = 0.1, note = "Seconds after reading ends before dictation starts" },
  },
}

local pending, reading, watcher, retry, poll, cutTimer, paused, resumeWatch = false, nil, nil, nil, nil, nil, false, nil
-- Claude's own dictation (⌘D in the prompt); quote_comment watches whether its mic is on.
-- The Claude app itself, by bundle id (a name lookup can match a helper or nothing useful).
local function claude()
  local a = hs.application.applicationsForBundleID("com.anthropic.claudefordesktop")[1]
  if a and a.isFrontmost then return a end
  return nil
end
local function claudeDictating()
  local ok, qc = pcall(require, "modules.quote_comment")
  return ok and type(qc) == "table" and qc.dictating and qc.dictating() or false
end
local function claudeDictate(release)
  local app = claude()
  if app and app:isFrontmost() and not claudeDictating() then hs.eventtap.keyStroke({ "cmd" }, "d", 0) end
  if release then release() end
end
-- Ducking: while Claude reads, lower Music and Spotify (only if playing), then put them back.
local ducked = {}
local DUCK_APPS = { "Music", "Spotify" }
local function osa(src) local ok, out = hs.osascript.applescript(src); return ok and out or nil end
-- Fades an app's volume from a to b over secs (about 12 steps a second); a new fade replaces the old.
local fades = {}
local function ramp(name, a, b, secs)
  if fades[name] then fades[name]:stop(); fades[name] = nil end
  local steps = math.max(1, math.floor(secs * 12))
  local i = 0
  local function set(v) osa(('tell application "%s" to set sound volume to %d'):format(name, math.floor(v + 0.5))) end
  if steps == 1 then return set(b) end
  fades[name] = hs.timer.doEvery(secs / steps, function()
    i = i + 1
    local t = i / steps
    t = t * t * (3 - 2 * t) -- ease in and out
    set(a + (b - a) * t)
    if i >= steps then fades[name]:stop(); fades[name] = nil end
  end)
end
local function duck()
  if next(ducked) or T("duck.level") >= 1 then return end
  for _, name in ipairs(DUCK_APPS) do
    if hs.application.get(name) and osa(('tell application "%s" to return player state as string'):format(name)) == "playing" then
      local v = osa(('tell application "%s" to return sound volume'):format(name))
      if v then
        ducked[name] = v
        ramp(name, v, math.floor(v * T("duck.level")), T("duck.fadeDown"))
      end
    end
  end
end
local function unduck()
  for name, v in pairs(ducked) do
    local now = tonumber(osa(('tell application "%s" to return sound volume'):format(name))) or v
    ramp(name, now, v, T("duck.fadeUp"))
  end
  ducked = {}
end

local lastPrompt = nil -- Claude's prompt field, from the latest scan
local QDIR = os.getenv("HOME") .. "/.hammerspoon/tmp/read_aloud_queue"

-- Every decision also goes to ~/.hammerspoon/tmp/read_aloud.log (the console clears on reload).
local LOGFILE = os.getenv("HOME") .. "/.hammerspoon/tmp/read_aloud.log"
local function log(msg)
  print("claude_read_aloud: " .. msg)
  local f = io.open(LOGFILE, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S  ") .. msg .. "\n"); f:close() end
end

-- Queue: files named <ms>-<n>-<session>.json, so a name sort is oldest first.
local function queue()
  local items = {}
  local maxAge = T("queue.maxAge") * 3600
  if not hs.fs.attributes(QDIR) then return items end
  for f in hs.fs.dir(QDIR) do
    if f:match("%.json$") then
      local path = QDIR .. "/" .. f
      local ms = tonumber(f:match("^(%d+)")) or 0
      local item = hs.json.read(path)
      if not item or os.time() - ms / 1000 > maxAge then os.remove(path)
      else item.path, item.name = path, f; table.insert(items, item) end
    end
  end
  table.sort(items, function(a, b) return a.name < b.name end)
  return items
end

local function norm(s) return (s or ""):lower():gsub("[^%a%d]", "") end

-- Every Read aloud button on screen with its reply's text, in one pass: a button's reply is
-- the text of its highest ancestor that holds no other Read aloud button.
local function scan()
  local app = claude()
  if not app then return {}, nil end
  local root = ax.applicationElement(app)
  root:setAttributeValue("AXManualAccessibility", true)
  local found, prompt = {}, nil
  local function walk(e, d)
    if d > 70 then return {}, "" end
    local role = e:attributeValue("AXRole")
    local desc = e:attributeValue("AXDescription") or ""
    if role == "AXButton" and desc == "Read aloud" then return { e }, "" end
    if role == "AXTextArea" and desc == "Prompt" then prompt = e end
    local buttons, parts = {}, {}
    if role == "AXStaticText" then
      local v = e:attributeValue("AXValue")
      if type(v) == "string" then parts[1] = v end
    end
    for _, c in ipairs(e:attributeValue("AXChildren") or {}) do
      local bs, t = walk(c, d + 1)
      for _, b in ipairs(bs) do table.insert(buttons, b) end
      if #buttons <= 1 and t ~= "" then table.insert(parts, t) end
    end
    local text = #buttons <= 1 and table.concat(parts, "") or ""
    if #buttons == 1 then found[buttons[1]] = text end
    return buttons, text
  end
  walk(root, 0)
  local list = {}
  for b, t in pairs(found) do table.insert(list, { button = b, text = norm(t) }) end
  lastPrompt = prompt or lastPrompt
  return list, prompt
end

-- The oldest queued reply whose button is on screen now.
local function nextOnScreen()
  local items = queue()
  if #items == 0 then return nil end
  local found = scan()
  for _, item in ipairs(items) do
    for _, f in ipairs(found) do
      if item.key ~= "" and f.text:find(item.key, 1, true) then return item, f.button, f.text end
    end
  end
  return nil
end

local function stopRetry()
  if retry then retry:stop(); retry = nil end
end

local function startDictation()
  if not T("dictate.after") then return log("dictation off") end
  local app = claude()
  if not app or not app:isFrontmost() then return log("no dictation: Claude not in front") end
  log("starting dictation")
  cc.withInput("read-aloud dictation", claudeDictate)
end

local tryRead, startRetry

-- Presses a Read aloud button, then hands keyboard focus straight back to the prompt with its
-- draft and caret untouched, so Enter sends the reply instead of pausing the reading.
local function press(button)
  cc.withInput("read-aloud", function()
    local p = lastPrompt
    local range = p and p:attributeValue("AXSelectedTextRange")
    button:performAction("AXPress")
    if p then
      hs.timer.doAfter(0.05, function()
        pcall(function()
          p:setAttributeValue("AXFocused", true)
          if range then p:setAttributeValue("AXSelectedTextRange", range) end
        end)
      end)
    end
  end)
end

local function watchReading(button, item)
  if poll then poll:stop() end
  if cutTimer then cutTimer:stop(); cutTimer = nil end
  local started, t0 = false, hs.timer.secondsSinceEpoch()
  reading = button
  poll = hs.timer.doEvery(0.5, function()
    if reading ~= button then poll:stop(); poll = nil; return end
    if paused then return end -- interrupted for dictation: not finished
    -- Matt started Claude's own dictation mid-reading: that's a cut-off, not an Interrupt.
    -- Stop this message for good and drop what was queued before it; new replies still read.
    if claudeDictating() then
      log("cut off by Claude dictation")
      poll:stop(); poll = nil
      M.cancel()
      return
    end
    local ok, desc = pcall(function() return button:attributeValue("AXDescription") end)
    local age = hs.timer.secondsSinceEpoch() - t0
    if ok and desc and desc ~= "Read aloud" then
      if not started then
        log("reading started, button now: " .. desc)
        duck()
        -- Stop before the hidden Actions line: Claude's voice reads the stored text, so time it.
        if item.cut then
          local secs = item.cut / T("speech.cps") + T("speech.pad")
          cutTimer = hs.timer.doAfter(secs, function()
            cutTimer = nil
            if reading == button then log("stopping before the Actions line"); press(button) end
          end)
        end
      end
      started = true; return
    end
    if started or not ok or age > T("start.timeout") then
      poll:stop(); poll = nil; reading = nil
      if cutTimer then cutTimer:stop(); cutTimer = nil end
      unduck()
      log(string.format("reading ended (started=%s age=%.1f) %s", tostring(started), age, item.name or ""))
      -- The press never took (button never turned to Pause): put the reply back for another try.
      if not started then
        local tries = (item.tries or 0) + 1
        if tries < 3 then
          local copy = { key = item.key, cut = item.cut, chars = item.chars, session = item.session, tries = tries }
          hs.json.write(copy, item.path, false, true)
          log("SKIPPED? never started; requeued (try " .. tries .. ") " .. item.name)
        else
          log("DROPPED after 3 tries: " .. item.name)
        end
      end
      -- More replies waiting? Keep trying until they're on screen; dictation only after the last.
      if #queue() > 0 then
        pending = true
        hs.timer.doAfter(0.5, function() if not tryRead() then startRetry() end end)
      elseif started then hs.timer.doAfter(T("dictate.delay"), startDictation) end
    end
  end)
end

-- Reads the oldest queued reply that's on screen if Claude is in front; true once pressed.
tryRead = function()
  local app = claude()
  if reading or not (pending and app and app:isFrontmost()) then return false end
  if claudeDictating() then return false end -- never start reading over Matt's dictation
  local item, button, text = nextOnScreen()
  if not item then return false end
  os.remove(item.path) -- put back by watchReading if the press never takes
  -- Two texts of one turn can share a bubble (one button): drop the others that match it too.
  for _, other in ipairs(queue()) do
    if other.key ~= "" and text:find(other.key, 1, true) then os.remove(other.path) end
  end
  pending = #queue() > 0
  if not pending then stopRetry() end
  log("reading " .. item.name)
  press(button)
  watchReading(button, item)
  return true
end

-- While replies wait and Claude is in front, keep checking (he may switch threads to one).
startRetry = function()
  stopRetry()
  retry = hs.timer.doEvery(1.5, function()
    if not pending then stopRetry(); return end
    local ok, err = pcall(function()
      local app = claude()
      if app and app:isFrontmost() then tryRead() end
    end)
    if not ok then log("retry error (kept going): " .. tostring(err)) end
  end)
end

function M.replyDone()
  pending = true
  log(string.format("turn ended: %d queued%s", #queue(), reading and " (behind the one playing)" or ""))
  if reading then return "queued" end -- the running read picks it up when it ends
  stopRetry()
  local app = claude()
  if not (app and app:isFrontmost()) then
    local name = T("away.sound")
    local snd = name ~= "" and hs.sound.getByName(name)
    if snd then snd:volume(T("away.volume")); snd:play() end
  end
  -- The Read aloud button appears a moment after the reply ends: check fast for a few
  -- seconds, then fall back to the slow retry (he may be in another app or thread).
  local t0 = hs.timer.secondsSinceEpoch()
  retry = hs.timer.doEvery(T("start.poll"), function()
    if not pending then stopRetry(); return end
    local ok, read = pcall(tryRead)
    if not ok then log("poll error (kept going): " .. tostring(read)) end
    if ok and read then return end
    if hs.timer.secondsSinceEpoch() - t0 > T("start.window") then startRetry() end
  end)
  return "ok"
end

-- The "Dictate after" setting, shared with the read-aloud mod's toggle (saved in the tweaks file).
function M.dictateAfter(value)
  if value ~= nil then
    local on = value == true or value == "on"
    tweaks.setValue(tweaks.dir .. "/claude_read_aloud.json", "dictate.after", on)
    return on and "on" or "off" -- the file watcher applies it a moment later
  end
  return T("dictate.after") and "on" or "off"
end

-- For checks: what it would do right now.
function M.status()
  local found = scan()
  local app = claude()
  local q = {}
  for _, i in ipairs(queue()) do table.insert(q, i.name .. ":" .. i.key:sub(1, 12)) end
  return string.format("pending=%s reading=%s front=%s buttons=%d queue=[%s]", tostring(pending), tostring(reading ~= nil),
    tostring(app and app:isFrontmost()), #found, table.concat(q, ", "))
end

-- For checks: the opening of each on-screen reply's text, as matching sees it.
function M.buttons()
  local out = {}
  for _, f in ipairs((scan())) do table.insert(out, f.text:sub(1, 40)) end
  return table.concat(out, "\n")
end

-- For checks: which queued reply would be read next (without pressing anything).
function M.peek()
  local item = nextOnScreen()
  return item and item.name or "none on screen"
end

-- True while Claude is reading a reply aloud (used by eye_breaks to hold its overlay).
function M.isReading() return reading ~= nil end

-- Interrupt: pause the reading (Claude's own pause, so it can continue), start dictation,
-- and resume the reading once dictation stops.
function M.interrupt()
  local b = reading
  if not b or paused then return "nothing reading" end
  if cutTimer then cutTimer:stop(); cutTimer = nil end -- the timed Actions stop restarts on resume
  paused = true
  press(b)
  log("interrupted for dictation")
  unduck()
  hs.timer.doAfter(0.3, function()
    cc.withInput("read-aloud interrupt dictation", claudeDictate)
  end)
  -- Watch Claude's mic: once it has been on and goes off again, carry on reading.
  local heard, t0 = false, hs.timer.secondsSinceEpoch()
  if resumeWatch then resumeWatch:stop() end
  resumeWatch = hs.timer.doEvery(0.5, function()
    if not paused or reading ~= b then resumeWatch:stop(); resumeWatch = nil; return end
    if claudeDictating() then heard = true; return end
    if heard or hs.timer.secondsSinceEpoch() - t0 > 600 then
      resumeWatch:stop(); resumeWatch = nil
      paused = false
      log("dictation done, resuming")
      duck()
      hs.timer.doAfter(0.6, function() press(b) end) -- let the text land first
    end
  end)
  return "ok"
end

function M.isPaused() return paused end
-- True while Claude's own dictation is listening (eye_breaks waits for it).
function M.isDictating() return claudeDictating() end
function M.isPending() return pending end

-- Matt typed or sent something: stop reading and drop that session's waiting replies
-- (all of them when no session is given).
function M.cancel(session)
  log("cut off (typed, sent or dictated)" .. (session and (" in " .. session) or "") .. ": queue dropped")
  unduck()
  for _, i in ipairs(queue()) do
    if not session or i.session == session then os.remove(i.path) end
  end
  pending = #queue() > 0
  if not pending then stopRetry() end
  if cutTimer then cutTimer:stop(); cutTimer = nil end
  if resumeWatch then resumeWatch:stop(); resumeWatch = nil end
  local wasPaused = paused
  paused = false
  local b = reading
  reading = nil
  if wasPaused then return "ok" end -- already silent
  if b then
    local ok, desc = pcall(function() return b:attributeValue("AXDescription") end)
    -- Only a message that is playing right now gets pressed (= paused). A message Claude already
    -- paused (its own dictation does that) is left alone: pressing it again would resume it.
    if ok and desc == "Pause" then pcall(function() b:performAction("AXPress") end) end
  end
  return "ok"
end

function M.start()
  hs.fs.mkdir(os.getenv("HOME") .. "/.hammerspoon/tmp")
  hs.fs.mkdir(QDIR)
  pending = #queue() > 0
  if pending then hs.timer.doAfter(1, function() startRetry() end) end -- replies left from before a reload
  watcher = hs.application.watcher.new(function(name, event)
    if name == "Claude" and event == hs.application.watcher.activated and pending then
      hs.timer.doAfter(T("return.delay"), tryRead)
    end
  end)
  watcher:start()
end

function M.stop()
  if watcher then watcher:stop(); watcher = nil end
  stopRetry()
  if poll then poll:stop(); poll = nil end
end

return M
