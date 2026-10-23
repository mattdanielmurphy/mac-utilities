-- modules/reload_indicator.lua
-- Subtle "config reloaded" cue: a small translucent ↻ in the bottom-left corner
-- of the primary screen that fades out. Replaces the old centered hs.alert;
-- centered notifications are reserved for genuinely important events.
-- Bottom-left is used because top-right holds claude_notify chips and
-- bottom-right holds the piano HUD / song key pill.

local M = {}

-- Feel knobs: ~/.hammerspoon/tweaks/reload_indicator.json, or the Tweaks panel (⌃⌥⌘T).
local T = require("modules.tweaks").open{
  app = "Reload indicator",
  file = require("modules.tweaks").dir .. "/reload_indicator.json",
  knobs = {
    ["badge.size"]   = { 28, min = 16, max = 64, step = 1, note = "Box size (px)" },
    ["badge.margin"] = { 14, min = 0, max = 60, step = 1, note = "Distance from the screen corner (px)" },
    ["badge.text"]   = { 20, min = 10, max = 48, step = 1, note = "Glyph size (pt)" },
    ["fade.hold"]    = { 1.2, min = 0, max = 5, step = 0.1, note = "Seconds fully visible" },
    ["fade.out"]     = { 0.8, min = 0, max = 3, step = 0.05, note = "Seconds to fade out" },
    ["look.darkAlpha"]  = { 0.55, min = 0.05, max = 1, step = 0.05, note = "Opacity in dark mode" },
    ["look.lightAlpha"] = { 0.45, min = 0.05, max = 1, step = 0.05, note = "Opacity in light mode" },
  },
  onChange = function() M.show() end, -- preview each change
}

local canvas, timer

local function isDark()
  return hs.host.interfaceStyle() == "Dark"
end

function M.show()
  if timer then timer:stop() end
  if canvas then canvas:delete() end

  local SIZE, MARGIN, HOLD, FADE = T("badge.size"), T("badge.margin"), T("fade.hold"), T("fade.out")
  local f = hs.screen.primaryScreen():frame()
  canvas = hs.canvas.new({ x = f.x + MARGIN, y = f.y + f.h - SIZE - MARGIN, w = SIZE, h = SIZE })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas:clickActivating(false)
  canvas:canvasMouseEvents(false, false, false, false)
  canvas:appendElements({
    type = "text", text = "↻",
    frame = { x = 0, y = 0, w = SIZE, h = SIZE },
    textSize = T("badge.text"), textAlignment = "center",
    textColor = isDark() and { white = 1, alpha = T("look.darkAlpha") } or { white = 0.15, alpha = T("look.lightAlpha") },
  })
  canvas:show()

  timer = hs.timer.doAfter(HOLD, function()
    if canvas then
      local c = canvas
      canvas = nil
      c:hide(FADE)
      timer = hs.timer.doAfter(FADE + 0.1, function() c:delete() end)
    end
  end)
end

return M
