-- Links into the Claude desktop app, shared by every notification that opens a thread
-- (claude-control banner, claude_notify toasts, claude_warm "goes cold" nudges).
--
-- A project thread opens with claude://code/project/<chan_…>?thread=<cmsg_…>.
-- That's the app's own project deep link (handler: "desktop_code_project_link_opened").
-- Forms that DON'T work: claude://claude.ai/epitaxy/project/<chan>?thread=… (the app keeps
-- only the path, so it lands on the thread list) and …/epitaxy/project/thread/<id>
-- (a share-link route: 404 for a cmsg id).
--
--   local links = require("modules.claude_links")
--   links.thread("cmsg_…")          -- URL for a thread (project read from the id)
--   links.open("cmsg_…" or url)     -- open a thread id, "chan_…:cmsg_…", or any URL

local M = {}

-- A thread root id carries its project's id: cmsg_<24-char project suffix><rest>.
function M.project(thread)
  local suffix = type(thread) == "string" and thread:match("^cmsg_(%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w)")
  return suffix and ("chan_" .. suffix) or nil
end

function M.thread(thread, project)
  if type(thread) ~= "string" or not thread:match("^cmsg_%w+$") then return nil end
  project = (type(project) == "string" and project:match("^chan_%w+$")) and project or M.project(thread)
  if not project then return nil end
  return "claude://code/project/" .. project .. "?thread=" .. thread
end

-- Anything a notifier was handed → a URL to open (nil if it can't be opened).
function M.resolve(target)
  if type(target) ~= "string" or target == "" then return nil end
  local chan, cmsg = target:match("^(chan_%w+):(cmsg_%w+)$")
  if cmsg then return M.thread(cmsg, chan) end
  if target:match("^cmsg_%w+$") then return M.thread(target) end
  return target
end

function M.open(target)
  local url = M.resolve(target)
  if url then hs.urlevent.openURL(url) end
  return url
end

return M
