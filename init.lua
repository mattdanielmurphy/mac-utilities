-- ~/.hammerspoon/init.lua
-- Entry point for the Hammerspoon configuration.
-- Loads modular components and sets up automatic config reloading.
--
-- ── Global Anchoring Convention ─────────────────────────────────────────────────
-- CRITICAL: All persistent Hammerspoon resources (watchers, window filters, event
-- taps, hotkeys) MUST be anchored to the global `_G.activeWatchers` table. Lua's
-- garbage collector silently collects `local` variables after a module finishes
-- loading, which destroys the underlying macOS event taps and causes silent
-- failures. Never assign these to local variables, and never implement periodic
-- timer "health checks" as a workaround — the root cause is always a missing
-- global reference.
-- ────────────────────────────────────────────────────────────────────────────────

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

-- Enable AppleScript and CLI (hs -c) control for instant reloading without app restarts
hs.allowAppleScript(true)
require("hs.ipc")

-- An `hs -c` client killed mid-command (timeout, watchdog) leaves a dead reply
-- port, and replying to it crashes Hammerspoon (SIGTRAP in ipc_sendMessage,
-- 2026-10-21). Skip replies to ports that are no longer valid.
do
  local mt = hs.getObjectMetatable("hs.ipc")
  if mt and mt.sendMessage and not mt._sendGuarded then
    local send = mt.sendMessage
    mt.sendMessage = function(port, ...)
      if not port:isValid() then return nil end
      return send(port, ...)
    end
    mt._sendGuarded = true
  end
end
pcall(require, "modules._keyprobe") -- TEMP key-timing test

-- Cap every accessibility call at 0.5 s (macOS default: 6 s). Hammerspoon's key
-- taps run on the same main thread as its AX queries, so one query to a hung app
-- (a frozen Claude window) used to stop all typing for seconds.
hs.axuielement.systemWideElement():setTimeout(0.5)

-- ── Config auto-reloader ────────────────────────────────────────────────────────
-- Watches the entire ~/.hammerspoon/ directory tree for .lua changes.
-- If every changed file is a running module with a stop(), only those modules
-- are swapped (ModuleManager.reload); the rest keep running. Anything else
-- (init.lua, shared libs, a failed swap) does a full reload.

-- Debounced: an agent saving several files reloads once, 1.5 s after the last
-- save, instead of once per file (each reload briefly holds up typing).
-- Only files Hammerspoon actually loads count (not tests/, tmp/, archive/).
local pendingFiles = {}

local function _applyChanges()
  local files = pendingFiles
  pendingFiles = {}
  local manager, suite = package.loaded["modules.module_manager"], package.loaded["modules.suite"]
  if not (manager and suite) then return hs.reload() end
  local targets = {}
  for file in pairs(files) do
    local name = file:match("/modules/([%w_]+)%.lua$")
    local id
    for modId, path in pairs(suite.pathOf) do
      if name and path == "modules." .. name then id = modId end
    end
    if not id then return hs.reload() end
    targets[id] = "modules." .. name
  end
  for id, path in pairs(targets) do
    if not manager.reload(id, path) then return hs.reload() end
    print("↻ hot-reloaded " .. id .. " (other modules untouched)")
  end
  require("modules.reload_indicator").show()
end

local function _reloadConfig(files)
  local relevant = false
  for _, file in ipairs(files) do
    if file:sub(-4) == ".lua" and not file:find("/tests/", 1, true)
      and not file:find("/tmp/", 1, true) and not file:find("/archive/", 1, true) then
      pendingFiles[file] = true
      relevant = true
    end
  end
  if not relevant then return end
  if activeWatchers.configReloadTimer then activeWatchers.configReloadTimer:stop() end
  activeWatchers.configReloadTimer = hs.timer.doAfter(1.5, _applyChanges)
end

activeWatchers.configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", _reloadConfig)
activeWatchers.configWatcher:start()

-- ── Modules ─────────────────────────────────────────────────────────────────────

-- Include paths for external submodule dependencies (e.g. qwerty_midi music-engine)
package.path = package.path .. ";/Users/matt/projects/qwerty-midi-hammerspoon/packages/music-engine/?.lua"

local suite = require("modules.suite") -- shared mode for Tyler's Mac (see UTILITIES.md)
local ModuleManager = require("modules.module_manager")
require("modules.menu_bar")
suite.startUpdater()

-- Modules start one per run-loop turn, not all in one go: Hammerspoon's key taps
-- (input_guard etc.) are live while later modules load, and every key press waits
-- for the main thread. Yielding between modules lets typing through during a
-- reload. Slow starts are logged so they can be fixed.
local startQueue = {}
local startedAt = hs.timer.absoluteTime()
local function startNext()
  local modulePath = table.remove(startQueue, 1)
  if not modulePath then
    print(string.format("✓ all modules started in %d ms", math.floor((hs.timer.absoluteTime() - startedAt) / 1e6)))
    return
  end
  local t = hs.timer.absoluteTime()
  local ok, mod = pcall(require, modulePath)
  if ok and mod then
    if type(mod) == "table" and mod.id then suite.pathOf[mod.id] = modulePath end
    local started, err = pcall(ModuleManager.register, mod)
    if not started then print("⚠️ Failed to start module " .. modulePath .. ": " .. tostring(err)) end
  else
    print("⚠️ Failed to load module " .. modulePath .. ": " .. tostring(mod))
  end
  local ms = (hs.timer.absoluteTime() - t) / 1e6
  if ms > 50 then print(string.format("⏱ %s took %d ms to start", modulePath, math.floor(ms))) end
  activeWatchers.moduleStartTimer = hs.timer.doAfter(0, startNext)
end

local function safeRegister(modulePath)
  if not suite.canLoad(modulePath) then return end
  table.insert(startQueue, modulePath)
  if #startQueue == 1 then activeWatchers.moduleStartTimer = hs.timer.doAfter(0, startNext) end
end

safeRegister("modules.input_guard") -- first: rate-limits scripted keystrokes
-- shelved 2026-10-22 (Matt): modules.right_command_raycast
-- shelved 2026-10-22 (Matt): modules.chrome_cmd_e
safeRegister("modules.keybindings")
-- shelved 2026-10-22 (Matt): modules.antigravity_submit
safeRegister("modules.clipboard")
safeRegister("modules.qwerty_midi")
safeRegister("modules.gemini_thread_search")
safeRegister("modules.wake_mute")
safeRegister("modules.click_lock")
safeRegister("modules.lecture_mode")
safeRegister("modules.selection_wrap")
safeRegister("modules.logic_editor")
safeRegister("modules.clamshell_guard")
safeRegister("modules.ui_recorder")
safeRegister("modules.ps5_dashboard")
safeRegister("modules.eye_breaks")
safeRegister("modules.claude_control")
safeRegister("modules.action_links") -- http://do.test/... links in chat run whitelisted actions
safeRegister("modules.claude_notify")
safeRegister("modules.claude_warm") -- toast before a waiting thread's cache goes cold
safeRegister("modules.piano_hud")
safeRegister("modules.song_key")
safeRegister("modules.otp_copy") -- 2FA codes from Messages/Mail → clipboard (G- stripped)
safeRegister("modules.fade_skip") -- media keys fade the song out before skipping
safeRegister("modules.claude_cmd_k")
safeRegister("modules.hey_claude")
safeRegister("modules.quote_comment") -- ⌥R: quote into Claude's box + dictate, queue, Return sends all
safeRegister("modules.thread_queue") -- ⏳ pill on Claude while a project thread has a /q message queued
safeRegister("modules.trackpad_mixer_summon") -- ⌃⌥⌘V: mixer on the built-in trackpad, one go
safeRegister("modules.wifi_home") -- on the iPhone hotspot with home Wi-Fi in range → rejoin home
safeRegister("modules.call_transcript") -- FaceTime call starts/ends → call-transcript start/stop
safeRegister("modules.tv_resync") -- ⌃⌥R: TV stuck on "no signal" with the lid shut → re-sync it
safeRegister("modules.tweaks_panel") -- ⌃⌥⌘T: sliders for every app's tweaks.json
safeRegister("modules.gif_picker") -- ⌃⌥⌘G: curated GIFs (Are.na) + Reddit, click copies


-- ── Startup confirmation ─────────────────────────────────────────────────────────

require("modules.reload_indicator").show()
