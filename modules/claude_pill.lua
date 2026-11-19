-- ~/.hammerspoon/modules/claude_pill.lua
-- Shared pieces for the small bars that sit on Claude's window: the quote queue
-- (quote_comment.lua, "❝ N queued") and the thread queue (thread_queue.lua, "⏳ N queued").
-- Anchored to Claude's window, not a screen corner, so they're exempt in hud_slots.json.
-- A thin wrapper over modules/pill.lua (the one canvas pill, components package B7): same API as before.
--
--   local pill = require("modules.claude_pill")
--   pill.label(text, size, color)                     -- centred system-font styled text
--   pill.elements{ id, x, w, h, text, size, accent, alpha }  -- filled pill + white label
--   pill.anchor(w, h, right, bottom)                  -- frame on Claude's front window, or nil
--   pill.isClaudeFront()

local base = require("modules.pill")

local M = {}

M.CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"

M.label = base.label
M.elements = base.elements

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
  return base.anchorIn(win:frame(), w, h, right, bottom)
end

return M
