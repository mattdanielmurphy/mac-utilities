local M = { id = "right_command_raycast", name = "Right Cmd -> Raycast" }
_G.activeWatchers = _G.activeWatchers or {}

local settingsKey = "rightCmdRaycast_settings"

local defaults = {
    initialHoldDelay = 100,
    longHoldDelay = 2000,
    showLongHoldIcon = true,
    targetApp = "Raycast",
    autoEnterOnRelease = true
}

local function getSettings()
    local s = hs.settings.get(settingsKey)
    if type(s) ~= "table" then return defaults end
    for k, v in pairs(defaults) do
        if s[k] == nil then s[k] = v end
    end
    return s
end

local function saveSettings(settings)
    hs.settings.set(settingsKey, settings)
end

local settingsWebview = nil

local function openSettingsWebview()
    if settingsWebview then
        settingsWebview:level(hs.drawing.windowLevels.floating)
        settingsWebview:bringToFront()
        settingsWebview:centerOnScreen()
        settingsWebview:show()
        settingsWebview:focus()
        local cfg = getSettings()
        settingsWebview:evaluateJavaScript("initSettings(" .. hs.json.encode(cfg) .. ")")
        return
    end

    local html = [[
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  :root {
    --bg: #fdfdfd;
    --card-bg: #ffffff;
    --text: #1a1a1a;
    --text-dim: #666666;
    --accent: #228be6;
    --border: #e9ecef;
    --shadow: 0 4px 12px rgba(0,0,0,0.05);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #101113;
      --card-bg: #1c1d1f;
      --text: #eceef4;
      --text-dim: #9499ad;
      --accent: #339af0;
      --border: #2c2e33;
      --shadow: 0 4px 12px rgba(0,0,0,0.2);
    }
  }
  body {
    margin: 0;
    padding: 24px;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    background: var(--bg);
    color: var(--text);
    user-select: none;
    -webkit-user-select: none;
  }
  .header {
    font-size: 20px;
    font-weight: 700;
    margin-bottom: 24px;
    letter-spacing: -0.5px;
  }
  .card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px;
    margin-bottom: 16px;
    box-shadow: var(--shadow);
  }
  .field { margin-bottom: 20px; }
  .field:last-child { margin-bottom: 0; }
  .label-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
    font-size: 14px;
    font-weight: 600;
  }
  .val-badge {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 12px;
    color: var(--accent);
    background: var(--accent);
    background-opacity: 0.1;
    padding: 3px 8px;
    border-radius: 6px;
    background: color-mix(in srgb, var(--accent), transparent 90%);
  }
  input[type="range"] {
    width: 100%;
    appearance: none;
    height: 6px;
    background: var(--border);
    border-radius: 3px;
    outline: none;
  }
  input[type="range"]::-webkit-slider-thumb {
    appearance: none;
    width: 16px;
    height: 16px;
    background: var(--accent);
    border-radius: 50%;
    cursor: pointer;
  }
  input[type="text"] {
    width: 100%;
    padding: 10px 12px;
    border-radius: 8px;
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font-size: 14px;
    box-sizing: border-box;
    outline: none;
  }
  input[type="text"]:focus { border-color: var(--accent); }
  .toggle-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .switch {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
  }
  .switch input { opacity: 0; width: 0; height: 0; }
  .slider {
    position: absolute; cursor: pointer; top: 0; left: 0; right: 0; bottom: 0;
    background-color: var(--border);
    transition: .3s; border-radius: 24px;
  }
  .slider:before {
    position: absolute; content: ""; height: 20px; width: 20px; left: 2px; bottom: 2px;
    background-color: white; transition: .3s; border-radius: 50%;
  }
  input:checked + .slider { background-color: var(--accent); }
  input:checked + .slider:before { transform: translateX(20px); }
</style>
</head>
<body>
  <div class="header">Right Command Settings</div>
  <div class="card">
    <div class="field">
      <div class="label-row">
        <span>Initial Hold Delay</span>
        <span class="val-badge" id="holdVal">100 ms</span>
      </div>
      <input type="range" id="initialHoldDelay" min="0" max="500" step="10">
    </div>
    <div class="field">
      <div class="label-row">
        <span>Long Hold Delay</span>
        <span class="val-badge" id="longHoldVal">2.0 s</span>
      </div>
      <input type="range" id="longHoldDelay" min="1000" max="5000" step="100">
    </div>
  </div>
  <div class="card">
    <div class="field">
      <div class="label-row"><span>Target Launcher Application</span></div>
      <input type="text" id="targetApp">
    </div>
  </div>
  <div class="card">
    <div class="field toggle-row">
      <div>
        <div style="font-size: 14px; font-weight: 600;">Show ⌘ Icon on Long Hold</div>
        <div style="font-size: 12px; color: var(--text-dim); margin-top: 4px;">Display badge on long press</div>
      </div>
      <label class="switch"><input type="checkbox" id="showLongHoldIcon"><span class="slider"></span></label>
    </div>
    <div class="field toggle-row" style="margin-top: 20px;">
      <div>
        <div style="font-size: 14px; font-weight: 600;">Auto-Enter on Release</div>
        <div style="font-size: 12px; color: var(--text-dim); margin-top: 4px;">Send Return key on release</div>
      </div>
      <label class="switch"><input type="checkbox" id="autoEnterOnRelease"><span class="slider"></span></label>
    </div>
  </div>
  <script>
    function save() {
      const cfg = {
        initialHoldDelay: parseInt(document.getElementById('initialHoldDelay').value),
        longHoldDelay: parseInt(document.getElementById('longHoldDelay').value),
        targetApp: document.getElementById('targetApp').value,
        showLongHoldIcon: document.getElementById('showLongHoldIcon').checked,
        autoEnterOnRelease: document.getElementById('autoEnterOnRelease').checked
      };
      if (window.webkit?.messageHandlers?.hsSettings) {
        window.webkit.messageHandlers.hsSettings.postMessage({ type: 'save', settings: cfg });
      }
    }
    document.querySelectorAll('input').forEach(el => el.addEventListener('input', () => {
        document.getElementById('holdVal').textContent = document.getElementById('initialHoldDelay').value + ' ms';
        document.getElementById('longHoldVal').textContent = (document.getElementById('longHoldDelay').value / 1000).toFixed(1) + ' s';
        save();
    }));
    window.initSettings = function(cfg) {
      document.getElementById('initialHoldDelay').value = cfg.initialHoldDelay;
      document.getElementById('holdVal').textContent = cfg.initialHoldDelay + ' ms';
      document.getElementById('longHoldDelay').value = cfg.longHoldDelay;
      document.getElementById('longHoldVal').textContent = (cfg.longHoldDelay / 1000).toFixed(1) + ' s';
      document.getElementById('targetApp').value = cfg.targetApp;
      document.getElementById('showLongHoldIcon').checked = cfg.showLongHoldIcon;
      document.getElementById('autoEnterOnRelease').checked = cfg.autoEnterOnRelease;
    };
  </script>
</body>
</html>
]]

    local userContent = hs.webview.usercontent.new("hsSettings")
    userContent:setCallback(function(msg)
        if msg.body and msg.body.type == "save" then
            saveSettings(msg.body.settings)
        end
    end)

    local screenFrame = hs.screen.mainScreen():frame()
    local w, h = 480, 520
    local rect = hs.geometry.rect(
        screenFrame.x + (screenFrame.w - w) / 2,
        screenFrame.y + (screenFrame.h - h) / 2,
        w,
        h
    )

    settingsWebview = hs.webview.new(rect, {
        developerExtras = false,
        allowNewWindows = false
    }, userContent)
    settingsWebview:level(hs.drawing.windowLevels.floating)
    settingsWebview:windowTitle("Right Command Settings")
    settingsWebview:bringToFront()
    settingsWebview:centerOnScreen()
    settingsWebview:show()
    settingsWebview:focus()

    local cfg = getSettings()
    hs.timer.doAfter(0.05, function()
        settingsWebview:evaluateJavaScript("initSettings(" .. hs.json.encode(cfg) .. ")")
    end)
end
_G.openRightCmdSettings = openSettingsWebview

local function flagsToModifierTable(flags)
    local mods = {}
    if not flags then return mods end
    if flags.shift then table.insert(mods, "shift") end
    if flags.alt then table.insert(mods, "alt") end
    if flags.ctrl then table.insert(mods, "ctrl") end
    if flags.fn then table.insert(mods, "fn") end
    return mods
end

-- State variables for Eventtap
local RIGHT_CMD_KEYCODE = 54
local ESCAPE_KEYCODE = 53
local COMMA_KEYCODE = 43

local isHoldingRightCmd = false
local modeActive = false
local isCancelled = false
local holdTimer = nil
local longHoldTimer = nil
local longHoldCanvas = nil
local keyBuffer = {}

local function getTargetApp()
    local name = getSettings().targetApp or "Raycast"
    return hs.application.find(name) or hs.application.get("com.raycast.macos")
end

local function flushBuffer()
    local app = getTargetApp()
    for _, evt in ipairs(keyBuffer) do
        local mods = flagsToModifierTable(evt.flags)
        local e = hs.eventtap.event.newKeyEvent(mods, evt.keycode, evt.isDown)
        if app then e:post(app) else e:post() end
    end
    keyBuffer = {}
end

local function triggerLauncher()
    if isCancelled then return end
    modeActive = true
    local appName = getSettings().targetApp or "Raycast"
    hs.application.launchOrFocus(appName)
    hs.timer.doAfter(0.02, function() flushBuffer() end)
end

if activeWatchers.rightCmdRaycastTap then
    activeWatchers.rightCmdRaycastTap:stop()
end

M.eventtap = hs.eventtap.new({
    hs.eventtap.event.types.flagsChanged,
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
}, function(event)
    local type = event:getType()
    local keycode = event:getProperty(hs.eventtap.event.properties.keyboardEventKeycode)
    local flags = event:getFlags()
    local cfg = getSettings()

    if type == hs.eventtap.event.types.flagsChanged then
        if keycode == RIGHT_CMD_KEYCODE then
            if flags.cmd then
                if not flags.alt and not flags.ctrl and not flags.shift and not flags.fn then
                    if not isHoldingRightCmd then
                        isHoldingRightCmd = true
                        modeActive = false
                        isCancelled = false
                        keyBuffer = {}
                        
                        if holdTimer then holdTimer:stop() end
                        holdTimer = hs.timer.doAfter((cfg.initialHoldDelay or 100) / 1000, function()
                            holdTimer = nil
                            if isHoldingRightCmd and not isCancelled then
                                triggerLauncher()
                            end
                        end)

                        if longHoldTimer then longHoldTimer:stop() end
                        longHoldTimer = hs.timer.doAfter((cfg.longHoldDelay or 2000) / 1000, function()
                            longHoldTimer = nil
                            if isHoldingRightCmd then
                                isCancelled = true
                                modeActive = false
                                
                                if cfg.showLongHoldIcon then
                                    if longHoldCanvas then longHoldCanvas:delete() end
                                    local screen = hs.screen.mainScreen():frame()
                                    local size = 60
                                    local margin = 30
                                    longHoldCanvas = hs.canvas.new({
                                        x = screen.w - size - margin,
                                        y = screen.h - size - margin,
                                        w = size,
                                        h = size
                                    })
                                    longHoldCanvas:appendElements({
                                        type = "rectangle", action = "fill",
                                        fillColor = { white = 0.1, alpha = 0.85 },
                                        roundedRectRadii = { xRadius = 12, yRadius = 12 }
                                    }, {
                                        type = "text", text = "⌘",
                                        textColor = { white = 1, alpha = 0.95 },
                                        textSize = 36, textAlignment = "center",
                                        frame = { x = 0, y = 8, w = size, h = size }
                                    })
                                    longHoldCanvas:show()
                                    hs.timer.doAfter(2.0, function()
                                        if longHoldCanvas then longHoldCanvas:delete(); longHoldCanvas = nil end
                                    end)
                                end
                            end
                        end)
                    end
                end
            else
                if isHoldingRightCmd then
                    if holdTimer then holdTimer:stop(); holdTimer = nil end
                    if longHoldTimer then longHoldTimer:stop(); longHoldTimer = nil end
                    
                    if modeActive and not isCancelled and cfg.autoEnterOnRelease then
                        flushBuffer()
                        local app = getTargetApp()
                        local retDown = hs.eventtap.event.newKeyEvent({}, "return", true)
                        local retUp = hs.eventtap.event.newKeyEvent({}, "return", false)
                        if app then
                            retDown:post(app)
                            retUp:post(app)
                        else
                            hs.eventtap.keyStroke({}, "return")
                        end
                    end
                    
                    isHoldingRightCmd = false
                    modeActive = false
                    isCancelled = false
                    keyBuffer = {}
                end
            end
        end
        return false
    end

    if isHoldingRightCmd then
        local char = event:getCharacters()
        if keycode == COMMA_KEYCODE or char == "," then
            if type == hs.eventtap.event.types.keyDown then
                if holdTimer then holdTimer:stop() end
                if longHoldTimer then longHoldTimer:stop() end
                
                isCancelled = true
                modeActive = false
                isHoldingRightCmd = false
                keyBuffer = {}
                
                local app = getTargetApp()
                if app then app:hide() end
                
                _G.openRightCmdSettings()
                return true
            end
            return true
        end

        if keycode == ESCAPE_KEYCODE then
            if type == hs.eventtap.event.types.keyDown then
                if holdTimer then holdTimer:stop(); holdTimer = nil end
                if longHoldTimer then longHoldTimer:stop(); longHoldTimer = nil end
                isCancelled = true
                modeActive = false
                keyBuffer = {}
            end
            return true
        end

        if not isCancelled then
            if holdTimer then
                holdTimer:stop()
                holdTimer = nil
                triggerLauncher()
            end

            local isDown = (type == hs.eventtap.event.types.keyDown)
            local app = getTargetApp()
            if modeActive and app and app:isFrontmost() then
                local mods = flagsToModifierTable(flags)
                local e = hs.eventtap.event.newKeyEvent(mods, keycode, isDown)
                e:post(app)
            else
                table.insert(keyBuffer, { keycode = keycode, flags = flags, isDown = isDown })
            end
        end
        return true
    end

    return false
end)

function M.start()
    if M.eventtap then
        M.eventtap:start()
        _G.activeWatchers.rightCmdRaycastTap = M.eventtap
    end
end

function M.stop()
    if M.eventtap then
        M.eventtap:stop()
    end
end

function M.isEnabled()
    return M.eventtap ~= nil and M.eventtap:isEnabled()
end

return M
