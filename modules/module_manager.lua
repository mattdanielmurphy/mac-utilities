_G.activeWatchers = _G.activeWatchers or {}
local ModuleManager = {}
ModuleManager.modules = {}
ModuleManager.registeredOrder = {}

-- ── Ownership tracking ──────────────────────────────────────────────────────────
-- Records the hotkeys, taps, timers, watchers, canvases, webviews and tasks a
-- module creates inside its start(). On hot reload, anything still active after
-- the old stop() is a leak: it is logged (console + cache/hot_reload_leaks.log)
-- and cleaned up, so a sloppy stop() can't make the new copy fire twice.
-- Objects created at require time or later in callbacks are not tracked.
local collecting = nil
local CONSTRUCTORS = {
    { "hotkey", "new" }, { "eventtap", "new" }, { "timer", "new" }, { "timer", "doAfter" },
    { "timer", "doEvery" }, { "timer", "doUntil" }, { "timer", "doWhile" },
    { "timer", "waitUntil" }, { "timer", "waitWhile" }, { "canvas", "new" }, { "webview", "new" },
    { "pathwatcher", "new" }, { "task", "new" }, { "caffeinate.watcher", "new" },
    { "application.watcher", "new" }, { "screen.watcher", "new" }, { "usb.watcher", "new" },
}
for _, c in ipairs(CONSTRUCTORS) do
    local lib = hs
    for part in c[1]:gmatch("[^.]+") do lib = lib and lib[part] end
    local original = lib and lib[c[2]]
    if type(original) == "function" then
        lib[c[2]] = function(...)
            local obj = original(...)
            if collecting and obj ~= nil and not collecting.seen[obj] then
                collecting.seen[obj] = true
                table.insert(collecting.list, obj)
            end
            return obj
        end
    end
end

local function trackedStart(entry, ...)
    local outer = collecting
    collecting = { list = entry.owned or {}, seen = {} }
    for _, o in ipairs(collecting.list) do collecting.seen[o] = true end
    local ok, err = pcall(entry.mod.start, ...)
    entry.owned = collecting.list
    collecting = outer
    return ok, err
end

local function isActive(o)
    for _, m in ipairs({ "isEnabled", "running", "isRunning", "isShowing", "isVisible" }) do
        local f = o[m]
        if type(f) == "function" then
            local ok, v = pcall(f, o)
            if ok and v then return true end
        end
    end
    return false
end

-- After stop(): report and dispose of whatever the module left running.
local function sweep(id, entry)
    local leaks = {}
    for _, o in ipairs(entry.owned or {}) do
        local kind = tostring(o):match("^(hs%.[%w_.]+)") or "object"
        if isActive(o) then table.insert(leaks, kind) end
        if kind == "hs.task" then
            if isActive(o) then pcall(o.terminate, o) end
        else
            for _, m in ipairs({ "stop", "delete" }) do
                if type(o[m]) == "function" then pcall(o[m], o) end
            end
        end
    end
    entry.owned = {}
    if #leaks > 0 then
        local line = string.format("%s  %s: stop() left %d running (%s), cleaned up",
            os.date("%Y-%m-%d %H:%M"), id, #leaks, table.concat(leaks, ", "))
        print("⚠️ hot reload leak: " .. line)
        local f = io.open(os.getenv("HOME") .. "/.hammerspoon/cache/hot_reload_leaks.log", "a")
        if f then f:write(line .. "\n") f:close() end
    end
    return leaks
end
ModuleManager._sweep = sweep

function ModuleManager.register(mod)
    if type(mod) ~= "table" or not mod.id then return end
    local id = mod.id
    local savedState = hs.settings.get("module_enabled_" .. id)
    local defaultEnabled = (mod.defaultEnabled == nil) and true or mod.defaultEnabled
    if require("modules.suite").shared then defaultEnabled = false end -- shared mode: opt in from the menu
    local enabled = (savedState == nil) and defaultEnabled or savedState
    
    ModuleManager.modules[id] = {
        mod = mod,
        enabled = enabled
    }
    table.insert(ModuleManager.registeredOrder, id)
    
    if enabled and mod.start then
        local ok, err = trackedStart(ModuleManager.modules[id], true)
        if not ok then error(err) end
    elseif not enabled and mod.stop then
        mod.stop()
    end
end

function ModuleManager.setEnabled(id, enabled)
    local entry = ModuleManager.modules[id]
    if not entry then return end
    entry.enabled = enabled
    hs.settings.set("module_enabled_" .. id, enabled)
    if enabled then
        if entry.mod.start then trackedStart(entry) end
    else
        if entry.mod.stop then entry.mod.stop() end
    end
end

-- Hot reload: swap one module's code without restarting the others.
-- Returns false when it can't be swapped safely; the caller then does a full reload.
function ModuleManager.reload(id, modulePath)
    local entry = ModuleManager.modules[id]
    if not entry or type(entry.mod.stop) ~= "function" then return false end
    pcall(entry.mod.stop)
    sweep(id, entry)
    package.loaded[modulePath] = nil
    local ok, mod = pcall(require, modulePath)
    if not ok or type(mod) ~= "table" or mod.id ~= id then
        print("⚠️ Hot reload failed for " .. modulePath .. ": " .. tostring(mod))
        return false
    end
    entry.mod = mod
    if entry.enabled and mod.start then
        local started, err = trackedStart(entry, true)
        if not started then print("⚠️ Hot reload start failed for " .. modulePath .. ": " .. tostring(err)) return false end
    end
    return true
end

function ModuleManager.toggle(id)
    local entry = ModuleManager.modules[id]
    if entry then
        ModuleManager.setEnabled(id, not entry.enabled)
    end
end

function ModuleManager.isEnabled(id)
    local entry = ModuleManager.modules[id]
    return entry and entry.enabled or false
end

return ModuleManager
