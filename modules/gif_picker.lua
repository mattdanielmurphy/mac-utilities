-- modules/gif_picker.lua
-- ⌃⌥⌘G: a window of GIFs that aren't lame.
--   Curated: GIFs hand-collected by people on Are.na (public channels like "Gif Stash" and
--            "crazy cool gifs"), merged, de-duplicated and shuffled daily. Synced once a day.
--   Reddit:  all-time top of r/HighQualityGifs + r/reactiongifs (public RSS, no key).
--   Starred: your own stash (☆ on any GIF).
-- Return searches everything: the curated library, your stars, and Reddit's GIF subreddits (all time).
-- Click a GIF to copy it (pastes animated into Messages, Slack, Discord...). Esc closes.
-- A standard window: move, resize, close; its frame is remembered.

local M = {
  id = "gif_picker",
  name = "GIF Picker (⌃⌥⌘G)",
  defaultEnabled = true,
}

local HOME = os.getenv("HOME")
local HERE = HOME .. "/.hammerspoon"
local HTML = HERE .. "/modules/gif_picker.html"
local CACHE = HOME .. "/Library/Caches/MDMA/gif-picker"
local LIBRARY = CACHE .. "/curated.json"
local DATA = HOME .. "/Library/Application Support/MDMA/gif-picker"
local STARS = DATA .. "/stars.json"
local FRAME_KEY = "gifPicker.frame"
local ARENA_UA = "MDMA-GIF-Picker/1.0" -- Are.na's Cloudflare blocks browser-looking agents from scripts
local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

local wv, hotkey, T
local current = { tab = "curated", query = "" }
local library = nil -- { fetched = os.time(), items = { ... } }
local syncing = false

-- ── Pure helpers (tested in tests/gif_picker_test.lua) ──────────────────────────

local function unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
    :gsub("&#(%d+);", function(n) return utf8.char(tonumber(n)) end):gsub("&amp;", "&"))
end
M._unescape = unescape

-- Reddit RSS (Atom) → { {id, title, source, full, link}, ... }; posts without a GIF are skipped.
function M.parseFeed(xml)
  local items = {}
  for entry in (xml or ""):gmatch("<entry>(.-)</entry>") do
    local id = entry:match("<id>(.-)</id>")
    local title = unescape(entry:match("<title>(.-)</title>") or "")
    local link = entry:match('<link href="(.-)"')
    local sub = entry:match('<category term="(.-)"')
    local html = unescape(entry:match('<content type="html">(.-)</content>') or "")
    local full
    for url in html:gmatch('href="(.-)"') do
      url = unescape(url)
      local u = url:gsub("%?.*$", "")
      -- Only Reddit-hosted GIFs: old imgur links often show imgur's "no longer available" image.
      if u:match("^https://i%.redd%.it/.+%.gif$") then full = full or url end
    end
    if id and full then
      items[#items + 1] = { id = id, title = title, source = sub and ("r/" .. sub) or "reddit", full = full, link = link }
    end
  end
  return items
end

-- One page of an Are.na channel's contents (decoded JSON) → GIF items no bigger than maxBytes.
function M.parseArena(doc, slug, maxBytes)
  local items = {}
  for _, b in ipairs((doc and doc.contents) or {}) do
    local img = b.image
    local orig = img and img.original
    if img and img.content_type == "image/gif" and orig and orig.url then
      local size = tonumber(orig.file_size) or 0
      if size == 0 or size <= maxBytes then
        items[#items + 1] = {
          id = "arena:" .. tostring(b.id), title = (b.title or "") .. " " .. (img.filename or ""),
          source = slug, full = orig.url, size = size, link = "https://www.are.na/block/" .. tostring(b.id),
        }
      end
    end
  end
  return items
end

-- Drop repeats: same file (URL without its query) or same byte size (the same GIF re-uploaded).
function M.dedupe(items)
  local seen, out = {}, {}
  for _, it in ipairs(items) do
    local urlKey = "u:" .. (it.full or ""):gsub("%?.*$", "")
    local sizeKey = (it.size or 0) > 0 and ("s:" .. it.size) or nil
    if not seen[urlKey] and not (sizeKey and seen[sizeKey]) and not seen["i:" .. it.id] then
      seen[urlKey], seen["i:" .. it.id] = true, true
      if sizeKey then seen[sizeKey] = true end
      out[#out + 1] = it
    end
  end
  return out
end

-- Deterministic shuffle (same seed → same order), so the mix changes daily, not per open.
function M.shuffle(items, seed)
  local out = {}
  for i, v in ipairs(items) do out[i] = v end
  local x = seed % 2147483647
  if x <= 0 then x = x + 2147483646 end
  for i = #out, 2, -1 do
    x = (x * 48271) % 2147483647
    local j = x % i + 1
    out[i], out[j] = out[j], out[i]
  end
  return out
end

function M.matches(item, query)
  local hay = ((item.title or "") .. " " .. (item.source or "")):lower():gsub("[_%-%.]", " ")
  for word in query:lower():gmatch("%S+") do
    if not hay:find(word, 1, true) then return false end
  end
  return true
end

local function urlencode(s)
  return (s:gsub("[^%w%-_.~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+"))
end

function M.redditURL(subs, query)
  local base = "https://www.reddit.com/r/" .. subs
  if query and query:match("%S") then
    return base .. "/search/.rss?restrict_sr=1&sort=relevance&t=all&limit=100&q=" .. urlencode(query)
  end
  return base .. "/top/.rss?limit=100&t=all"
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
  hs.fs.mkdir(HOME .. "/Library/Caches/MDMA")
  hs.fs.mkdir(CACHE)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function decode(s)
  local ok, v = pcall(function() return s and hs.json.decode(s) end)
  return ok and v or nil
end

local function loadStars()
  local list = decode(readFile(STARS))
  return type(list) == "table" and list or {}
end

local function saveStars(list)
  hs.fs.mkdir(HOME .. "/Library/Application Support/MDMA")
  hs.fs.mkdir(DATA)
  local f = io.open(STARS, "w")
  if f then f:write(#list > 0 and hs.json.encode(list, true) or "[]") f:close() end
end

local function list(knob)
  local out = {}
  for s in tostring(T(knob)):gmatch("[^%s,+]+") do out[#out + 1] = s end
  return out
end

-- ── Window plumbing ─────────────────────────────────────────────────────────────

local function js(fn, payload)
  if wv then wv:evaluateJavaScript(fn .. "(" .. hs.json.encode({ payload }) .. "[0])") end
end

local function render(items, status)
  local starred = {}
  for _, s in ipairs(loadStars()) do starred[s.id] = true end
  js("render", { tab = current.tab, query = current.query, items = M.dedupe(items), starred = starred,
    status = status or "", tile = T("grid.tileWidth"), batch = T("grid.batch"), parallel = T("grid.parallelLoads") })
end

local function curatedItems()
  if not library then return {} end
  return M.shuffle(library.items, tonumber(os.date("%Y%m%d")) + (current.shuffle or 0))
end

-- ── Curated library: Are.na channels, synced once a day ─────────────────────────

local function syncLibrary(onDone)
  if syncing then return end
  syncing = true
  local slugs, maxPages, maxBytes = list("curated.channels"), T("curated.pagesPerChannel"), T("curated.maxMB") * 1e6
  local collected, failed, ci, page = {}, 0, 1, 1
  local function step()
    if ci > #slugs then
      syncing = false
      if #collected > 0 then
        library = { fetched = os.time(), items = M.dedupe(collected) }
        writeFile(LIBRARY, hs.json.encode(library))
      end
      if onDone then onDone(failed) end
      return
    end
    local slug = slugs[ci]
    local url = "https://api.are.na/v2/channels/" .. slug .. "/contents?per=100&page=" .. page
    hs.http.asyncGet(url, { ["User-Agent"] = ARENA_UA }, function(code, body)
      local doc = code == 200 and decode(body) or nil
      local got = doc and M.parseArena(doc, slug, maxBytes) or {}
      for _, it in ipairs(got) do collected[#collected + 1] = it end
      if not doc then failed = failed + 1 end
      local more = doc and doc.contents and #doc.contents == 100 and page < maxPages
      if more then page = page + 1 else ci, page = ci + 1, 1 end
      step()
    end)
  end
  step()
end

local function ensureLibrary()
  if not library then library = decode(readFile(LIBRARY)) end
  local stale = not library or (os.time() - (library.fetched or 0)) > T("curated.refreshHours") * 3600
  if stale and not syncing then
    if not library or #library.items == 0 then js("loading", "Collecting curated GIFs (first time only)…") end
    syncLibrary(function(failed)
      if wv and current.tab == "curated" and current.query == "" then
        render(curatedItems(), failed > 0 and (failed .. " channel(s) didn't load; showing the rest.") or "")
      end
    end)
  end
  return library and #library.items > 0
end

-- ── Feeds ───────────────────────────────────────────────────────────────────────

local function fetchReddit(url, onItems)
  local file = CACHE .. "/feed-" .. hs.hash.MD5(url) .. ".rss"
  local attr = hs.fs.attributes(file)
  if attr and (os.time() - attr.modification) < T("reddit.cacheMinutes") * 60 then
    return onItems(M.parseFeed(readFile(file)), "")
  end
  hs.http.asyncGet(url, { ["User-Agent"] = UA }, function(code, body)
    if code == 200 and body and body:find("<feed") then
      writeFile(file, body)
      onItems(M.parseFeed(body), "")
    else
      local cached = readFile(file)
      local why = code == 429 and "Reddit is rate-limiting" or ("Reddit didn't answer (" .. tostring(code) .. ")")
      onItems(M.parseFeed(cached), cached and (why .. "; showing its last results.") or (why .. "; try again in a minute."))
    end
  end)
end

local function show()
  local tab, query = current.tab, current.query
  if query ~= "" then
    ensureLibrary()
    local local_ = {}
    for _, it in ipairs(loadStars()) do if M.matches(it, query) then local_[#local_ + 1] = it end end
    for _, it in ipairs(library and library.items or {}) do if M.matches(it, query) then local_[#local_ + 1] = it end end
    js("loading", "Searching for “" .. query .. "”…")
    fetchReddit(M.redditURL(T("search.subreddits"), query), function(items, status)
      if not wv or current.query ~= query then return end
      local all = {}
      for _, it in ipairs(local_) do all[#all + 1] = it end
      for _, it in ipairs(items) do all[#all + 1] = it end
      render(all, status)
    end)
  elseif tab == "starred" then
    render(loadStars(), "")
  elseif tab == "reddit" then
    js("loading", "Loading…")
    fetchReddit(M.redditURL(T("reddit.subreddits")), function(items, status)
      if wv and current.tab == "reddit" and current.query == "" then render(items, status) end
    end)
  else
    if ensureLibrary() then render(curatedItems(), "") end
  end
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
      writeFile(file, body)
      put(body)
    else
      js("notify", "Couldn't download that GIF (" .. tostring(code) .. ").")
    end
  end)
end

local function toggleStar(item)
  local stars, found = loadStars(), nil
  for i, s in ipairs(stars) do if s.id == item.id then found = i end end
  if found then table.remove(stars, found) else table.insert(stars, 1, item) end
  saveStars(stars)
  if current.tab == "starred" and current.query == "" then render(stars, "") else js("setStar", { id = item.id, on = not found }) end
end

local function onMessage(msg)
  local m = msg.body
  if type(m) ~= "table" then return end
  if m.type == "tab" and m.tab then
    current.tab, current.query = m.tab, ""
    show()
  elseif m.type == "search" then
    current.query = m.query or ""
    show()
  elseif m.type == "shuffle" then
    current.shuffle = (current.shuffle or 0) + 1
    current.tab, current.query = "curated", ""
    show()
  elseif m.type == "copy" and type(m.item) == "table" then
    copy(m.item)
  elseif m.type == "star" and type(m.item) == "table" then
    toggleStar(m.item)
  elseif m.type == "open" and m.url then
    hs.urlevent.openURL(m.url)
  elseif m.type == "ready" then
    show()
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
    :shadow(true) -- the standard window shadow, so its edges stand apart from white windows behind
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
      ["curated.channels"] = { "gif-stash crazy-cool-gifs gif-t zoracle-gifs gifs-for-future-viewing another-gif-channel gif-collection reactions-ch7umpwxfg",
        note = "Are.na channel slugs (are.na/<user>/<slug>), space-separated" },
      ["curated.pagesPerChannel"] = { 5, min = 1, max = 20, step = 1, note = "Pages of 100 blocks read per channel" },
      ["curated.maxMB"] = { 6, min = 1, max = 30, step = 1, note = "Skip GIFs bigger than this (MB)" },
      ["curated.refreshHours"] = { 24, min = 1, max = 168, step = 1, note = "Hours between curated library syncs" },
      ["reddit.subreddits"] = { "HighQualityGifs+reactiongifs", note = "Reddit tab: subreddits joined with +" },
      ["search.subreddits"] = { "reactiongifs+HighQualityGifs+gifs+gifsthatkeepongiving+BetterEveryLoop+perfectloops+wholesomegifs+AnimalsBeingDerps",
        note = "Return searches these subreddits (all time) plus the curated library" },
      ["reddit.cacheMinutes"] = { 60, min = 5, max = 1440, step = 5, note = "Minutes before a Reddit page is fetched again" },
      ["grid.tileWidth"] = { 200, min = 120, max = 480, step = 10, note = "Width of each GIF tile in px" },
      ["grid.batch"] = { 24, min = 6, max = 120, step = 6, note = "GIFs added per scroll step" },
      ["grid.parallelLoads"] = { 4, min = 1, max = 16, step = 1, note = "GIFs downloaded at the same time" },
      ["copy.closeAfter"] = { true, note = "Close the window after copying a GIF" },
      ["cache.keepDays"] = { 30, min = 1, max = 365, step = 1, note = "Days a copied GIF stays cached" },
    },
    onChange = function() if wv then show() end end,
  }
  hotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "G", M.toggle)
  pruneCache()
end

function M.stop()
  if hotkey then hotkey:delete() hotkey = nil end
  M.close()
end

return M
