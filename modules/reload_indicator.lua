-- modules/reload_indicator.lua
-- Subtle "config reloaded" cue: a small translucent ↻ in the bottom-left corner
-- of the primary screen that fades out. Replaces the old centered hs.alert;
-- centered notifications are reserved for genuinely important events.
-- Bottom-left is used because top-right holds claude_notify chips and
-- bottom-right holds the piano HUD / song key pill.

local M = {}

local SIZE   = 28
local MARGIN = 14
local HOLD   = 1.2   -- seconds fully visible
local FADE   = 0.8   -- seconds to fade out

local canvas, timer

local function isDark()
  return hs.host.interfaceStyle() == "Dark"
end

function M.show()
  if timer then timer:stop() end
  if canvas then canvas:delete() end

  local f = hs.screen.primaryScreen():frame()
  canvas = hs.canvas.new({ x = f.x + MARGIN, y = f.y + f.h - SIZE - MARGIN, w = SIZE, h = SIZE })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas:clickActivating(false)
  canvas:canvasMouseEvents(false, false, false, false)
  canvas:appendElements({
    type = "text", text = "↻",
    frame = { x = 0, y = 0, w = SIZE, h = SIZE },
    textSize = 20, textAlignment = "center",
    textColor = isDark() and { white = 1, alpha = 0.55 } or { white = 0.15, alpha = 0.45 },
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
