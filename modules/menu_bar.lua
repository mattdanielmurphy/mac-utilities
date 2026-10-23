_G.activeWatchers = _G.activeWatchers or {}
local ModuleManager = require("modules.module_manager")
local brand = require("modules.brand")

-- ⚙︎ menu layout: a few big actions on top (with their hotkeys shown), then the
-- module toggles grouped into submenus so the menu stays short and scannable.

-- Module id → group. Anything not listed lands in "Other", so new modules
-- still show up; add them here to file them properly.
local GROUPS = {
    { title = "Claude & AI", icon = "🤖", ids = {
        "claude_control", "claude_notify", "claude_warm", "claude_cmd_k", "hey_claude",
        "quote_comment", "gemini_thread_search", "ui_recorder" } },
    { title = "Typing & Mouse", icon = "⌨️", ids = {
        "input_guard", "selection_wrap", "click_lock", "clipboard",
        "otp_copy" } },
    { title = "Music & Audio", icon = "🎹", ids = {
        "qwerty_midi", "piano_hud", "song_key", "fade_skip", "wake_mute", "trackpad_mixer_summon" } },
    { title = "Focus & Study", icon = "📚", ids = { "eye_breaks", "lecture_mode", "logic_editor" } },
    { title = "Mac & Devices", icon = "💻", ids = {
        "clamshell_guard", "tv_resync", "wifi_home", "ps5_dashboard", "cloud_mounter_guard", "tweaks_panel" } },
}
local OTHER = { title = "Other", icon = "🧩" }

local function groupOf(id)
    for _, g in ipairs(GROUPS) do
        for _, gid in ipairs(g.ids) do
            if gid == id then return g end
        end
    end
    return OTHER
end

-- Title with the hotkey right-aligned in grey, like a native menu shortcut.
-- Falls back to plain text if styled text isn't available.
local function withKey(text, key)
    if not key then return text end
    local ok, styled = pcall(function()
        local font = { name = ".AppleSystemUIFont", size = 14 }
        local para = { tabStops = { { location = 270, tabStopType = "right" } } }
        return hs.styledtext.new(text .. "\t", { font = font, paragraphStyle = para })
            .. hs.styledtext.new(key, { font = font, paragraphStyle = para,
                color = { list = "System", name = "secondaryLabelColor" } })
    end)
    return ok and styled or (text .. "   " .. key)
end

local function enabled(id)
    local entry = ModuleManager.modules[id]
    return entry and entry.enabled
end

-- Runs fn(module) on a module, switching it on first if it was off.
local function useModule(id, path, fn)
    return function()
        if ModuleManager.modules[id] and not enabled(id) then ModuleManager.setEnabled(id, true) end
        local ok, mod = pcall(require, path)
        if ok and type(mod) == "table" then fn(mod) end
    end
end

-- Only modules that loaded on this Mac get a quick action (off ones switch on when used).
local function quickActions()
    local items = {}
    local function add(id, item)
        if ModuleManager.modules[id] then table.insert(items, item) end
    end

    local recording = _G.UIRecorder and _G.UIRecorder.isRecording()
    add("ui_recorder", {
        title = withKey(recording and "⏹  Stop Screen Recording" or "⏺  Record Screen for Claude", "⌃⌥⌘R"),
        tooltip = "Records the screen plus every click and key. Stop it, then ask Claude to review the latest recording.",
        fn = useModule("ui_recorder", "modules.ui_recorder", function(m) m.toggle() end),
    })
    add("tweaks_panel", {
        title = withKey("🎚  Tweaks Panel", "⌃⌥⌘T"),
        tooltip = "Sliders for every app's feel knobs.",
        fn = useModule("tweaks_panel", "modules.tweaks_panel", function(m) m.toggle() end),
    })
    add("gemini_thread_search", {
        title = withKey("🔎  Search AI Threads", "⌃⌘G"),
        tooltip = "Search past Claude, Gemini and Antigravity threads.",
        fn = useModule("gemini_thread_search", "modules.gemini_thread_search", function(m) if m.show then m.show() end end),
    })
    add("trackpad_mixer_summon", {
        title = withKey("🎛  Trackpad Mixer", "⌃⌥⌘V"),
        tooltip = "Lends the built-in trackpad to the mixer for one go.",
        fn = function() hs.distributednotifications.post("ca.mattmurphy.trackpad-mixer.summon") end,
    })
    add("logic_editor", {
        title = withKey("∀  Logic Symbol Editor", "⌃⌘L"),
        tooltip = "Write logic formulas with a cheat sheet, then paste them.",
        fn = useModule("logic_editor", "modules.logic_editor", function(m) if m.show then m.show() end end),
    })
    return items
end

local function moduleGroups(suite)
    local byGroup, order = {}, {}
    local onCount, total = 0, 0
    for _, id in ipairs(ModuleManager.registeredOrder) do
        local entry = ModuleManager.modules[id]
        if entry then
            local g = groupOf(id)
            if not byGroup[g] then byGroup[g] = { on = 0, items = {} } end
            local bucket = byGroup[g]
            table.insert(bucket.items, {
                title = entry.mod.name or id,
                checked = entry.enabled,
                tooltip = suite.describe(id), -- hover for what it does (from UTILITIES.md)
                fn = function() ModuleManager.toggle(id) end,
            })
            total = total + 1
            if entry.enabled then bucket.on = bucket.on + 1; onCount = onCount + 1 end
        end
    end
    for _, g in ipairs(GROUPS) do table.insert(order, g) end
    table.insert(order, OTHER)

    local items = { { title = string.format("Utilities: %d of %d on", onCount, total), disabled = true } }
    for _, g in ipairs(order) do
        local bucket = byGroup[g]
        if bucket then
            table.sort(bucket.items, function(a, b) return a.title:lower() < b.title:lower() end)
            table.insert(items, {
                title = string.format("%s  %s   (%d/%d on)", g.icon, g.title, bucket.on, #bucket.items),
                menu = bucket.items,
            })
        end
    end
    table.insert(items, { title = "❓  What Do These Do?", fn = suite.showGuide })
    return items
end

local mb = hs.menubar.new(true, "AI-OS Controls")
if mb then
    mb:setTitle("⚙︎")
    mb:setTooltip(brand.name)
    -- ⚙︎ carries Reload, Console and Quit, so the stock 🔨 icon is redundant.
    hs.menuIcon(false)

    local function append(dst, src) for _, v in ipairs(src) do table.insert(dst, v) end end

    mb:setMenu(function()
        local menuItems = {}
        local suite = require("modules.suite")

        table.insert(menuItems, { title = brand.name .. ": " .. brand.longName, disabled = true })
        table.insert(menuItems, { title = "-" })

        local quick = quickActions()
        if #quick > 0 then
            append(menuItems, quick)
            table.insert(menuItems, { title = "-" })
        end

        if suite.shared then
            -- Tyler's Mac: no lidstay, just the utilities.
            table.insert(menuItems, { title = "⬇️  Update Now", fn = function() suite.update(true) end })
        else
            local lid = require("modules.lid_sleep").menuItem()
            if type(lid) == "table" and type(lid.title) == "string" then lid.title = "🌙  " .. lid.title end
            table.insert(menuItems, lid)
        end
        table.insert(menuItems, { title = "-" })

        append(menuItems, moduleGroups(suite))
        table.insert(menuItems, { title = "-" })

        -- Engine (Hammerspoon) actions, tucked into one submenu.
        table.insert(menuItems, { title = "🔨  Hammerspoon", menu = {
            { title = "Reload Config", fn = function() hs.reload() end },
            { title = "Open Config", fn = function() hs.execute("open ~/.hammerspoon/init.lua") end },
            { title = "-" },
            { title = "Console...", fn = function() hs.openConsole() end },
            { title = "Preferences...", fn = function() hs.openPreferences() end },
            { title = "-" },
            { title = "Built on Hammerspoon…", fn = function() hs.openAbout() end },
            { title = "Check for Hammerspoon Updates...", fn = function() hs.checkForUpdates() end },
        } })
        table.insert(menuItems, { title = "Quit " .. brand.name, fn = function() hs.application.get("Hammerspoon"):kill() end })

        return menuItems
    end)

    _G.activeWatchers.moduleMenuBar = mb

    -- Bartender hides ⚙︎ in its drawer; ⌃⌥⌘M pops the same menu at the mouse.
    _G.activeWatchers.moduleMenuHotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "M", function()
        mb:popupMenu(hs.mouse.absolutePosition())
    end)
end
