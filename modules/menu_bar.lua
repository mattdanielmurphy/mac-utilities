_G.activeWatchers = _G.activeWatchers or {}
local ModuleManager = require("modules.module_manager")
local brand = require("modules.brand")

local mb = hs.menubar.new(true, "AI-OS Controls")
if mb then
    mb:setTitle("⚙︎")
    mb:setTooltip(brand.name)
    -- ⚙︎ carries Reload, Console and Quit, so the stock 🔨 icon is redundant.
    hs.menuIcon(false)

    local function notifyCompanionFailure(details)
        hs.notify.new({
            title = brand.name,
            informativeText = details or "The companion did not respond. Start it with `la start aios-server` and try again.",
        }):send()
    end

    local function postCompanionControl(route, payload, retry)
        local url = "http://127.0.0.1:3031/api/companion/" .. route
        hs.http.asyncPost(url, hs.json.encode(payload or {}), { ["Content-Type"] = "application/json" }, function(status, body)
            if status and status >= 200 and status < 300 then return end
            if not retry then
                local uid = hs.execute("/usr/bin/id -u", true):gsub("%s+", "")
                local service = "gui/" .. uid .. "/com.matt.agent.aios-server"
                local task = hs.task.new("/bin/launchctl", nil, { "kickstart", "-k", service })
                if task and task:start() then
                    _G.activeWatchers.companionControlRetry = hs.timer.doAfter(2, function()
                        postCompanionControl(route, payload, true)
                    end)
                    return
                end
            end
            notifyCompanionFailure("Could not reach the AI-OS companion. Start it with `la start aios-server` and try again.")
        end)
    end
    
    mb:setMenu(function()
        local menuItems = {}

        local suite = require("modules.suite")
        if suite.shared then
            -- Tyler's Mac: no AI-OS companion or lidstay, just the utilities.
            table.insert(menuItems, { title = brand.name, disabled = true })
            table.insert(menuItems, { title = "What Do These Do?", fn = suite.showGuide })
            table.insert(menuItems, { title = "Update Now", fn = function() suite.update(true) end })
        else
        table.insert(menuItems, { title = brand.name, disabled = true })
        table.insert(menuItems, { title = "Open Perplexity", fn = function()
            postCompanionControl("show", { provider = "perplexity" })
        end })
        table.insert(menuItems, { title = "Open Gemini", fn = function()
            postCompanionControl("show", { provider = "gemini" })
        end })
        table.insert(menuItems, { title = "Hide Companion", fn = function()
            postCompanionControl("hide")
        end })
        table.insert(menuItems, { title = "Search AI Threads (⌃⌘G)", fn = function()
            local gts = require("modules.gemini_thread_search")
            if gts and gts.show then gts.show() end
        end })
        table.insert(menuItems, require("modules.lid_sleep").menuItem())
        table.insert(menuItems, { title = "Preview Claude Banner", menu = {
            { title = "Light pill", fn = function() if claudeControl then claudeControl.demo("light") end end },
            { title = "Full banner", fn = function() if claudeControl then claudeControl.demo("full") end end },
        } })
        end
        table.insert(menuItems, { title = "-" })

        -- 1. Module Toggles
        table.insert(menuItems, { title = "Modules", disabled = true })
        for _, id in ipairs(ModuleManager.registeredOrder) do
            local entry = ModuleManager.modules[id]
            if entry then
                table.insert(menuItems, {
                    title = entry.mod.name or id,
                    checked = entry.enabled,
                    tooltip = suite.describe(id), -- hover for what it does (from UTILITIES.md)
                    fn = function()
                        ModuleManager.toggle(id)
                    end
                })
            end
        end
        
        -- 2. Separator
        table.insert(menuItems, { title = "-" })
        
        -- 3. Engine (Hammerspoon) actions
        table.insert(menuItems, { title = "Reload Config", fn = function() hs.reload() end })
        table.insert(menuItems, { title = "Open Config", fn = function() hs.execute("open ~/.hammerspoon/init.lua") end })
        table.insert(menuItems, { title = "-" })
        table.insert(menuItems, { title = "Console...", fn = function() hs.openConsole() end })
        table.insert(menuItems, { title = "Preferences...", fn = function() hs.openPreferences() end })
        table.insert(menuItems, { title = "-" })
        table.insert(menuItems, { title = "Built on Hammerspoon…", fn = function() hs.openAbout() end })
        table.insert(menuItems, { title = "Check for Hammerspoon Updates...", fn = function() hs.checkForUpdates() end })
        table.insert(menuItems, { title = "-" })
        table.insert(menuItems, { title = "Quit " .. brand.name, fn = function() hs.application.get("Hammerspoon"):kill() end })
        
        return menuItems
    end)
    
    _G.activeWatchers.moduleMenuBar = mb

    -- Bartender hides ⚙︎ in its drawer; ⌃⌥⌘M pops the same menu at the mouse.
    _G.activeWatchers.moduleMenuHotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "M", function()
        mb:popupMenu(hs.mouse.absolutePosition())
    end)
end
