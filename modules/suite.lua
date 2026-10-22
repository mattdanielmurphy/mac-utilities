-- ~/.hammerspoon/modules/suite.lua
-- Shared mode: lets someone else (Tyler) run the public copy of this config
-- (github.com/mattdanielmurphy/mac-utilities, published by bin/ship-public).
--
--   • Shared mode is on when ~/.hammerspoon/profile contains "shared" (install.sh
--     writes it; the file is gitignored, so Matt's Mac never has it).
--   • In shared mode only the modules in SHAREABLE load, they all start switched
--     off (turn them on from the ⚙︎ menu), and the config pulls updates every hour.
--   • UTILITIES.md describes each shareable module for Tyler and his Claude.
--     tests/suite_test.lua fails if the two lists drift apart.

local M = {}

local HOME = os.getenv("HOME")
local CONFIG_DIR = HOME .. "/.hammerspoon"

-- Module paths safe to run on another Mac (no ai-os, no Matt-only paths).
M.SHAREABLE = {
  "modules.click_lock",
  "modules.clipboard",
  "modules.eye_breaks",
  "modules.fade_skip",
  "modules.wake_mute",
  "modules.selection_wrap",
  "modules.right_command_raycast",
  "modules.chrome_cmd_e",
  "modules.keybindings",
  "modules.input_guard",
  "modules.clamshell_guard",
  "modules.logic_editor",
  "modules.piano_hud",
  "modules.song_key",
}

local shareableSet = {}
for _, p in ipairs(M.SHAREABLE) do shareableSet[p] = true end

local function readProfile()
  local f = io.open(CONFIG_DIR .. "/profile", "r")
  if not f then return nil end
  local s = f:read("*l")
  f:close()
  return s and s:gsub("%s+", "") or nil
end

M.shared = (readProfile() == "shared")

function M.canLoad(modulePath)
  return not M.shared or shareableSet[modulePath] == true
end

-- ── Descriptions (UTILITIES.md is the single source) ──────────────────────────
-- Each `### modules.x` section is a short paragraph. The menu shows it as that
-- toggle's tooltip, and the guide window shows the whole file.

M.GUIDE = CONFIG_DIR .. "/UTILITIES.md"
M.pathOf = {} -- module id → module path, filled by init.lua as modules load

local descCache
function M.descriptions()
  if descCache then return descCache end
  descCache = {}
  local f = io.open(M.GUIDE, "r")
  if not f then return descCache end
  local current
  for line in f:lines() do
    local path = line:match("^### (modules%.[%w_]+)")
    if path then
      current = path
    elseif line:match("^#") then
      current = nil
    elseif current and line:match("%S") then
      local text = line:gsub("%*%*", ""):gsub("`", "")
      descCache[current] = descCache[current] and (descCache[current] .. " " .. text) or text
    end
  end
  f:close()
  return descCache
end

function M.describe(id)
  local path = M.pathOf[id]
  return path and M.descriptions()[path] or nil
end

-- Guide window: UTILITIES.md rendered. Escape or clicking elsewhere closes it.
function M.showGuide()
  local f = io.open(M.GUIDE, "r")
  if not f then return end
  local md = f:read("*a")
  f:close()
  local css = [[<style>body{font:14px -apple-system,sans-serif;color:#1d1d1f;background:#fbfbf8;
    margin:0;padding:20px 28px;line-height:1.45}h1{font-size:20px}h2{font-size:15px;color:#5b6b4f}
    h3{font-size:11px;color:#8a8f86;font-weight:500;margin:18px 0 2px}code{font:12px ui-monospace,monospace}
    @media (prefers-color-scheme:dark){body{background:#1c1d1b;color:#e8e8e3}h2{color:#a9b89c}}</style>]]
  local html = css .. hs.doc.markdown.convert(md)
  local sf = hs.screen.mainScreen():frame()
  local w, h = 560, math.min(720, sf.h - 80)
  if _G.activeWatchers.suiteGuide then _G.activeWatchers.suiteGuide:delete() end
  local wv = hs.webview.new({ x = sf.x + (sf.w - w) / 2, y = sf.y + 40, w = w, h = h })
  wv:windowStyle({ "titled", "closable", "resizable" }):windowTitle("Matt's Utilities")
    :closeOnEscape(true):deleteOnClose(true):allowTextEntry(true):html(html)
  wv:windowCallback(function(action, view, focused)
    if action == "focusChange" and not focused then
      _G.activeWatchers.suiteGuide = nil
      view:delete()
    elseif action == "closing" then
      _G.activeWatchers.suiteGuide = nil
    end
  end)
  _G.activeWatchers.suiteGuide = wv
  wv:show():bringToFront(true)
  local win = wv:hswindow()
  if win then win:focus() end
end

-- ── Updater (shared mode only) ────────────────────────────────────────────────
-- `git pull --ff-only origin main`. A pull that changes files trips init.lua's
-- config watcher, which reloads Hammerspoon. --ff-only refuses rather than
-- merging if the clone has local commits, so nothing of Tyler's is overwritten.

local UPDATE_EVERY = 60 * 60

function M.update(manual)
  local task = hs.task.new("/usr/bin/git", function(code, out, err)
    if code ~= 0 then
      print("⚠️ [suite] update failed: " .. tostring(err))
      if manual then hs.alert.show("Update failed: see Hammerspoon console") end
    elseif manual and out:find("Already up to date") then
      hs.alert.show("Already up to date")
    end
  end, { "-C", CONFIG_DIR, "pull", "--ff-only", "origin", "main" })
  if task then task:start() end
end

function M.startUpdater()
  if not M.shared then return end
  hs.autoLaunch(true) -- start with the Mac, like any menu bar app
  _G.activeWatchers = _G.activeWatchers or {}
  _G.activeWatchers.suiteFirstUpdate = hs.timer.doAfter(60, function() M.update(false) end)
  _G.activeWatchers.suiteUpdater = hs.timer.doEvery(UPDATE_EVERY, function() M.update(false) end)
end

return M
