-- modules/gif_picker.lua
-- ⌃⌥⌘G: a window of GIFs that aren't lame. Pulls the top posts of hand-picked subreddits
-- (r/HighQualityGifs, r/reactiongifs by default) through Reddit's public RSS, so no API key.
-- Click a GIF to copy it (pastes animated into Messages, Slack, Discord...), ☆ stars it into
-- your own stash, typing filters, Enter searches Reddit, Esc closes.
-- A standard window: move, resize, close; its frame is remembered.
-- Feeds are cached for an hour (Reddit rate-limits keyless requests); on an error the cache shows.

local M = {
  id = "gif_picker",
  name = "GIF Picker (⌃⌥⌘G)",
  defaultEnabled = true,
}

local HOME = os.getenv("HOME")
local HERE = HOME .. "/.hammerspoon"
local HTML = HERE .. "/modules/gif_picker.html"
local CACHE = HOME .. "/Library/Caches/MDMA/gif-picker"
local DATA = HOME .. "/Library/Application Support/MDMA/gif-picker"
local STARS = DATA .. "/stars.json"
local FRAME_KEY = "gifPicker.frame"
local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

local wv, hotkey, T
local current = { tab = "week", query = "" }

-- ── Pure helpers (tested in tests/gif_picker_test.lua) ──────────────────────────

local function unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
    :gsub("&#(%d+);", function(n) return utf8.char(tonumber(n)) end):gsub("&amp;", "&"))
end
M._unescape = unescape

-- Reddit RSS (Atom) → { {id, title, sub, thumb, full, link}, ... }; posts without a GIF are skipped.
function M.parseFeed(xml)
  local items = {}
  for entry in (xml or ""):gmatch("<entry>(.-)</entry>") do
    local id = entry:match("<id>(.-)</id>")
    local title = unescape(entry:match("<title>(.-)</title>") or "")
    local link = entry:match('<link href="(.-)"')
    local sub = entry:match('<category term="(.-)"')
    local html = unescape(entry:match('<content type="html">(.-)</content>') or "")
    local full, thumb
    for url in html:gmatch('href="(.-)"') do
      url = unescape(url)
      local u = url:gsub("%?.*$", "")
      if u:match("^https://i%.redd%.it/.+%.gif$") then full = full or url
      elseif u:match("^https://i%.imgur%.com/.+%.gifv?$") then full = full or u:gsub("%.gifv$", ".gif") end
    end
    for url in html:gmatch('src="(.-)"') do
      url = unescape(url)
      if url:gsub("%?.*$", ""):match("%.gif$") then thumb = thumb or url end
    end
    if id and full then
      items[#items + 1] = { id = id, title = title, sub = sub, thumb = thumb or full, full = full, link = link }
    end
  end
  return items
end

function M.feedURL(subs, tab, query)
  local base = "https://www.reddit.com/r/" .. subs
  if query and query:match("%S") then
    local q = query:gsub("[^%w%-_.~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+")
    return base .. "/search/.rss?restrict_sr=1&sort=top&t=all&limit=100&q=" .. q
  end
  return base .. "/top/.rss?limit=100&t=" .. (tab == "all" and "all" or "week")
end

-- ── Files ───────────────────────────────────────────────────────────────────────

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeFile(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function loadStars()
  local s = readFile(STARS)
  local ok, list = pcall(function() return s and hs.json.decode(s) end)
  return (ok and type(list) == "table") and list or {}
end

local function saveStars(list)
  hs.fs.mkdir(HOME .. "/Library/Application Support/MDMA")
  hs.fs.mkdir(DATA)
  writeFile(STARS, #list > 0 and hs.json.encode(list, true) or "[]")
end

local function cacheFile(url)
  return CACHE .. "/feed-" .. hs.hash.MD5(url) .. ".rss"
end

-- ── Window ──────────────────────────────────────────────────────────────────────

local function js(fn, payload)
  if wv then wv:evaluateJavaScript(fn .. "(" .. hs.json.encode({ payload }) .. "[0])") end
end

local function render(items, status)
  local starred = {}
  for _, s in ipairs(loadStars()) do starred[s.id] = true end
  js("render", { tab = current.tab, query = current.query, items = items, starred = starred,
    status = status or "", columnWidth = T("grid.columnWidth") })
end

local function showFeed()
  if current.tab == "starred" then
    render(loadStars(), "")
    return
  end
  local url = M.feedURL(T("feed.subreddits"), current.tab, current.query)
  local file = cacheFile(url)
  local attr = hs.fs.attributes(file)
  local fresh = attr and (os.time() - attr.modification) < T("feed.cacheMinutes") * 60
  if fresh then
    render(M.parseFeed(readFile(file)), "")
    return
  end
  js("loading", current.query ~= "" and ("Searching Reddit for “" .. current.query .. "”…") or "Loading…")
  local want = url
  hs.http.asyncGet(url, { ["User-Agent"] = UA }, function(code, body)
    if not wv or M.feedURL(T("feed.subreddits"), current.tab, current.query) ~= want then return end
    if code == 200 and body and body:find("<feed") then
      hs.fs.mkdir(HOME .. "/Library/Caches/MDMA")
      hs.fs.mkdir(CACHE)
      writeFile(file, body)
      render(M.parseFeed(body), "")
    else
      local cached = readFile(file)
      local why = code == 429 and "Reddit is rate-limiting" or ("Reddit didn't answer (" .. tostring(code) .. ")")
      render(M.parseFeed(cached), cached and (why .. "; showing the last copy.") or (why .. ". Try again in a minute."))
    end
  end)
end

-- Copy: GIF data plus a file URL, so apps that only take files (Messages) still get it animated.
local function copy(item)
  local file = CACHE .. "/" .. hs.hash.MD5(item.full) .. ".gif"
  local function put(data)
    hs.pasteboard.writeAllData({ ["com.compuserve.gif"] = data, ["public.file-url"] = "file://" .. file })
    js("notify", "Copied. ⌘V to paste.")
    if T("copy.closeAfter") then hs.timer.doAfter(0.4, function() M.close() end) end
  end
  local cached = readFile(file)
  if cached then return put(cached) end
  js("notify", "Downloading…")
  hs.http.asyncGet(item.full, { ["User-Agent"] = UA }, function(code, body)
    if code == 200 and body and body:sub(1, 3) == "GIF" then
      hs.fs.mkdir(HOME .. "/Library/Caches/MDMA")
      hs.fs.mkdir(CACHE)
      writeFile(file, body)
      put(body)
    else
      js("notify", "Couldn't download that GIF (" .. tostring(code) .. ").")
    end
  end)
end

local function toggleStar(item)
  local list, found = loadStars(), nil
  for i, s in ipairs(list) do if s.id == item.id then found = i end end
  if found then table.remove(list, found) else table.insert(list, 1, item) end
  saveStars(list)
  if current.tab == "starred" then render(list, "") else js("setStar", { id = item.id, on = not found }) end
end

local function onMessage(msg)
  local m = msg.body
  if type(m) ~= "table" then return end
  if m.type == "tab" and m.tab then
    current.tab, current.query = m.tab, ""
    showFeed()
  elseif m.type == "search" then
    current.query = m.query or ""
    if current.tab == "starred" then current.tab = "week" end
    showFeed()
  elseif m.type == "copy" and type(m.item) == "table" then
    copy(m.item)
  elseif m.type == "star" and type(m.item) == "table" then
    toggleStar(m.item)
  elseif m.type == "open" and m.url then
    hs.urlevent.openURL(m.url)
  elseif m.type == "ready" then
    showFeed()
  elseif m.type == "close" then
    M.close()
  end
end
M._onMessage = onMessage

function M.close()
  if not wv then return end
  local w = wv
  wv = nil
  hs.settings.set(FRAME_KEY, w:frame())
  w:delete()
end

local function open()
  local html = readFile(HTML)
  if not html then
    print("⚠️ gif_picker: missing " .. HTML)
    return
  end
  local s = hs.screen.mainScreen():frame()
  local frame = hs.settings.get(FRAME_KEY) or { x = s.x + (s.w - 760) / 2, y = s.y + 80, w = 760, h = 620 }
  local uc = hs.webview.usercontent.new("gifs")
  uc:setCallback(onMessage)
  wv = hs.webview.new(frame, { developerExtrasEnabled = false }, uc)
    :windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    :windowTitle("GIFs")
    :level(hs.drawing.windowLevels.floating)
    :allowTextEntry(true)
    :closeOnEscape(false)
    :deleteOnClose(true)
    :windowCallback(function(action, w)
      if action == "closing" and wv == w then
        hs.settings.set(FRAME_KEY, w:frame())
        wv = nil
      end
    end)
    :html(html)
    :show()
  wv:bringToFront(true)
  local win = wv:hswindow()
  if win then win:focus() end
end

function M._webview() return wv end -- for debugging

function M.toggle()
  if wv then M.close() else open() end
end

-- Copied GIFs stay cached so a re-copy is instant; ones untouched for cache.keepDays are dropped.
local function pruneCache()
  local cutoff = os.time() - T("cache.keepDays") * 86400
  if not hs.fs.attributes(CACHE) then return end
  for name in hs.fs.dir(CACHE) do
    local path = CACHE .. "/" .. name
    local attr = name:match("%.gif$") and hs.fs.attributes(path)
    if attr and attr.access < cutoff then os.remove(path) end
  end
end

function M.start()
  local tweaks = require("modules.tweaks")
  T = tweaks.open{
    app = "GIF Picker",
    file = tweaks.dir .. "/gif_picker.json",
    knobs = {
      ["feed.subreddits"] = { "HighQualityGifs+reactiongifs", note = "Subreddits joined with +" },
      ["feed.cacheMinutes"] = { 60, min = 5, max = 1440, step = 5, note = "Minutes before a feed is fetched again" },
      ["grid.columnWidth"] = { 220, min = 120, max = 480, step = 10, note = "Width of each GIF tile in px" },
      ["copy.closeAfter"] = { true, note = "Close the window after copying a GIF" },
      ["cache.keepDays"] = { 30, min = 1, max = 365, step = 1, note = "Days a copied GIF stays cached" },
    },
    onChange = function() if wv then showFeed() end end,
  }
  hotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "G", M.toggle)
  pruneCache()
end

function M.stop()
  if hotkey then hotkey:delete() hotkey = nil end
  M.close()
end

return M
