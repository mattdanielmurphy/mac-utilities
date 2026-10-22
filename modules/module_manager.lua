_G.activeWatchers = _G.activeWatchers or {}
local ModuleManager = {}
ModuleManager.modules = {}
ModuleManager.registeredOrder = {}

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
        mod.start(true)
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
        if entry.mod.start then entry.mod.start() end
    else
        if entry.mod.stop then entry.mod.stop() end
    end
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
