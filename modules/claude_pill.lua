-- ~/.hammerspoon/modules/claude_pill.lua
-- Shared pieces for the small bars that sit on Claude's window: the quote queue
-- (quote_comment.lua, "❝ N queued") and the thread queue (thread_queue.lua, "⏳ N queued").
-- Anchored to Claude's window, not a screen corner, so they're exempt in hud_slots.json.
--
--   local pill = require("modules.claude_pill")
--   pill.label(text, size, color)                     -- centred system-font styled text
--   pill.elements{ id, x, w, h, text, size, accent, alpha }  -- filled pill + white label
--   pill.anchor(w, h, right, bottom)                  -- frame on Claude's front window, or nil
--   pill.isClaudeFront()

local M = {}

M.CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"

function M.label(text, size, color)
  return hs.styledtext.new(text, { font = { name = ".AppleSystemUIFont", size = size },
    color = color, paragraphStyle = { alignment = "center" } })
end

-- A filled rounded pill with a white centred label; `id` makes it clickable (mouseUp).
function M.elements(o)
  local x, h, size = o.x or 0, o.h, o.size
  local r = { xRadius = h / 2, yRadius = h / 2 }
  return {
    { id = o.id, type = "rectangle", action = "fill", fillColor = { hex = o.accent, alpha = o.alpha },
      frame = { x = x, y = 0, w = o.w, h = h }, roundedRectRadii = r, trackMouseUp = o.id ~= nil },
    { type = "text", frame = { x = x, y = (h - size * 1.3) / 2, w = o.w, h = h },
      text = M.label(o.text, size, o.color or { white = 1 }) },
  }
end

function M.isClaudeFront()
  local front = hs.application.frontmostApplication()
  return front ~= nil and front:bundleID() == M.CLAUDE_BUNDLE
end

-- Bottom-right of Claude's front window, `right`/`bottom` px in. nil when Claude isn't in front.
function M.anchor(w, h, right, bottom)
  if not M.isClaudeFront() then return nil end
  local front = hs.application.frontmostApplication()
  local win = front:focusedWindow() or front:mainWindow()
  if not win then return nil end
  local f = win:frame()
  return { x = f.x + f.w - w - right, y = f.y + f.h - h - bottom, w = w, h = h }
end

return M
