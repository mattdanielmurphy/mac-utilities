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

-- Errors go to logs/errors.log, never a popped-up console; shared mode also hides the Dock/menu icons.
local sharedProfile = (function() local f = io.open(os.getenv("HOME") .. "/.hammerspoon/profile") local p = f and f:read("l") if f then f:close() end return p == "shared" end)()
require("modules.quiet_errors").install(sharedProfile)

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

-- Enable AppleScript and CLI (hs -c) control for instant reloading without app restarts
hs.allowAppleScript(true)
require("hs.ipc")

-- Keep-alive (ai-os scripts/hs_keepalive.sh, launchd ca.mattmurphy.hs-keepalive) relaunches
-- Hammerspoon after a crash. A clean Quit or reload leaves this marker so it isn't relaunched.
do
  local stateDir = os.getenv("HOME") .. "/.hammerspoon/state"
  hs.shutdownCallback = function()
    local f = io.open(stateDir .. "/clean_exit", "w")
    if f then f:write(tostring(os.time())); f:close() end
  end
  local flag = stateDir .. "/relaunched_after_crash"
  local f = io.open(flag, "r")
  if f then
    local at = tonumber(f:read("*a")) or 0; f:close(); os.remove(flag)
    if os.time() - at < 120 then
      hs.notify.new({ title = "Hammerspoon restarted", informativeText = "It crashed and was reopened on its own.",
        withdrawAfter = 6 }):send()
    end
  end
end

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
-- Cap every accessibility call at 0.5 s (macOS default: 6 s). Hammerspoon's key
-- taps run on the same main thread as its AX queries, so one query to a hung app
-- (a frozen Claude window) used to stop all typing for seconds.
hs.axuielement.systemWideElement():setTimeout(0.5)

-- Keyboard-freeze guard (2026-11-09): skips AX calls to an app that just answered
-- slowly, and logs slow key handlers/timers to cache/main_thread.log. Must load
-- before module_manager and every module (it wraps hs.eventtap.new / hs.timer).
do
  local ok, err = pcall(require, "modules.main_thread_guard")
  if not ok then print("⚠️ main_thread_guard failed: " .. tostring(err)) end
end

-- ── Config auto-reloader ────────────────────────────────────────────────────────
-- Watches the entire ~/.hammerspoon/ directory tree for .lua changes.
-- If every changed file is a running module with a stop(), only those modules
-- are swapped (ModuleManager.reload); the rest keep running. Anything else
-- (init.lua, shared libs, a failed swap) does a full reload.

-- Debounced: an agent saving several files reloads once, 1.5 s after the last
-- save, instead of once per file (each reload briefly holds up typing).
-- Only files Hammerspoon actually loads count (not tests/, tmp/, archive/).
local pendingFiles = {}

-- Shared files that hold live state for everyone: a change to one restarts everything.
local FULL_RELOAD_LIBS = { tweaks = true, suite = true, module_manager = true, menu_bar = true,
  reload_indicator = true, main_thread_guard = true }

local function _readFile(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*a"); f:close(); return s
end

-- Registered modules that use shared file `lib`, directly or through other shared files.
-- Returns nil when a full reload is needed instead.
local function _dependentsOf(lib, suite)
  local dir = os.getenv("HOME") .. "/.hammerspoon/modules/"
  local libs, queue, seen = {}, { lib }, { [lib] = true }
  local found = {}
  while #queue > 0 do
    local name = table.remove(queue, 1)
    if FULL_RELOAD_LIBS[name] then return nil end
    libs[#libs + 1] = name
    local needle = '"modules.' .. name .. '"'
    for file in hs.fs.dir(dir) do
      local other = file:match("^([%w_]+)%.lua$")
      if other and not seen[other] and _readFile(dir .. file):find(needle, 1, true) then
        seen[other] = true
        local id
        for modId, path in pairs(suite.pathOf) do
          if path == "modules." .. other then id = modId end
        end
        if id then found[id] = "modules." .. other
        elseif package.loaded["modules." .. other] then table.insert(queue, other) end
      end
    end
  end
  return found, libs
end

local function _applyChanges()
  local files = pendingFiles
  pendingFiles = {}
  local manager, suite = package.loaded["modules.module_manager"], package.loaded["modules.suite"]
  if not (manager and suite) then return hs.reload() end
  local targets, dropLibs = {}, {}
  for file in pairs(files) do
    local name = file:match("/%.hammerspoon/modules/([%w_]+)%.lua$")
    if not name then return hs.reload() end -- init.lua, rcmd.lua, vendor…
    local id
    for modId, path in pairs(suite.pathOf) do
      if path == "modules." .. name then id = modId end
    end
    if id then
      targets[id] = "modules." .. name
    elseif not package.loaded["modules." .. name] then
      print("↻ " .. name .. ".lua changed but isn't running; nothing reloaded")
    else
      -- A shared file: reload only the modules that use it, not all of Hammerspoon.
      local deps, libs = _dependentsOf(name, suite)
      if not deps then return hs.reload() end
      for _, l in ipairs(libs) do dropLibs[#dropLibs + 1] = "modules." .. l end
      for depId, path in pairs(deps) do targets[depId] = path end
    end
  end
  for _, lib in ipairs(dropLibs) do package.loaded[lib] = nil end
  local any = false
  for id, path in pairs(targets) do
    if not manager.reload(id, path) then return hs.reload() end
    print("↻ hot-reloaded " .. id .. " (other modules untouched)")
    any = true
  end
  if any then require("modules.reload_indicator").show() end
end

local function _reloadConfig(files)
  local relevant = false
  for _, file in ipairs(files) do
    if file:sub(-4) == ".lua" and not file:find("/tests/", 1, true)
      and not file:find("/.claude/", 1, true) and not file:find("/.agy-mcp/", 1, true) -- agent worktrees
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
safeRegister("modules.bt_mic_guard") -- keeps Bluetooth headphones out of call mode
safeRegister("modules.click_lock")
safeRegister("modules.side_buttons") -- mouse side buttons: back/forward in every app
safeRegister("modules.lecture_mode")
safeRegister("modules.selection_wrap")
safeRegister("modules.logic_editor")
safeRegister("modules.logic_keys") -- hold E, A, N... for symbols in any app
safeRegister("modules.question_keys") -- Claude question cards: 1–4 tick, Return next, type → Other
safeRegister("modules.study_quiz") -- hourly Logic quiz takeover until Nov 5 (Tweaks: "Logic quiz")
safeRegister("modules.forced_checkin") -- mandatory morning breathing + mindfulness overlay (Tweaks: "Morning check-in")
safeRegister("modules.clamshell_guard")
safeRegister("modules.ui_recorder")
safeRegister("modules.ps5_dashboard")
safeRegister("modules.eye_breaks")
safeRegister("modules.claude_control")
safeRegister("modules.action_links") -- http://do.test/... links in chat run whitelisted actions
safeRegister("modules.claude_notify")
safeRegister("modules.claude_warm") -- toast before a waiting thread's cache goes cold
safeRegister("modules.piano_hud")
safeRegister("modules.piano_lock") -- Yamaha piano → Ableton (IAC ch 16), out-of-key notes dropped; weekly scale
safeRegister("modules.song_key")
safeRegister("modules.otp_copy") -- 2FA codes from Messages/Mail → clipboard (G- stripped)
safeRegister("modules.fade_skip") -- media keys fade the song out before skipping
safeRegister("modules.tv_brightness") -- brightness keys move the TV as well as the laptop
safeRegister("modules.claude_cmd_k")
safeRegister("modules.hey_claude")
safeRegister("modules.quote_comment") -- ⌥R: quote into Claude's box + dictate, queue, Return sends all
safeRegister("modules.enter_guard") -- Return in Claude's box that looks like a slip is swallowed + pill; Return again sends
safeRegister("modules.thread_queue") -- ⏳ pill on Claude while a project thread has a /q message queued
safeRegister("modules.trackpad_mixer_summon") -- ⌃⌥⌘V: mixer on the built-in trackpad, one go
safeRegister("modules.wifi_home") -- on the iPhone hotspot with home Wi-Fi in range → rejoin home
safeRegister("modules.ambient_listen") -- always-listening recorder + knobs
safeRegister("modules.live_caption") -- live captions strip + listening chip (laptop screen)
safeRegister("modules.field_pill") -- dictation pill at any focused text field: Enter pastes, Shift+Enter sends, Esc×3 discards
safeRegister("modules.dictation_history") -- ⌃⌥⌘D: everything you dictated, newest first, with Copy (2026-11-09)
safeRegister("modules.call_transcript") -- FaceTime call starts/ends → call-transcript start/stop
safeRegister("modules.security_prompt_guard") -- security/permission prompt steals focus → Space/Return ignored ~1s
safeRegister("modules.tv_resync") -- ⌃⌥R: TV stuck on "no signal" with the lid shut → re-sync it
safeRegister("modules.tweaks_panel") -- ⌃⌥⌘T: sliders for every app's tweaks.json
safeRegister("modules.thread_effort") -- Tweaks panel "Claude threads": the effort ceiling, written to Claude settings
safeRegister("modules.claude_read_aloud") -- Coordinator reply → presses Claude's own Read aloud, then dictation
safeRegister("modules.gif_picker") -- ⌃⌥⌘G: curated GIFs (Are.na) + Reddit, click copies
safeRegister("modules.readthrough_float") -- Readthrough floats beside Claude, per thread
safeRegister("modules.claude_sidebar") -- ⌥T: your own Claude sidebar on the left of its window (2026-11-10)


-- ── Startup confirmation ─────────────────────────────────────────────────────────

require("modules.reload_indicator").show()
