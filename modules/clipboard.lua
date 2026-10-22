-- modules/clipboard.lua
-- Monitors the system clipboard for duplicate lines and offers a one-key cleanup.
-- Hotkeys (Opt+D / Escape) are bound dynamically only while the notification is live,
-- and are automatically removed after 5 seconds if no action is taken.
--
-- ── Global Anchoring ────────────────────────────────────────────────────────────
-- The persistent pasteboard watcher is anchored to `activeWatchers.clipboardWatcher`
-- to prevent garbage collection. The dynamic hotkeys and timer are intentionally
-- ephemeral (local variables) — they are created and destroyed on demand.
-- ────────────────────────────────────────────────────────────────────────────────

local M = {
  id = "clipboard",
  name = "Clipboard Cleaner"
}

-- ── Private state ──────────────────────────────────────────────────────────────

local _hotkeys   = {}   -- holds the two dynamic hs.hotkey objects
local _timer     = nil  -- holds the auto-dismiss hs.timer object
local _notify    = nil  -- holds the active hs.notify object
local _isSelfWrite = false -- flag to prevent infinite loops when updating clipboard

-- ── Helpers ────────────────────────────────────────────────────────────────────

--- Remove all dynamic hotkeys and cancel the auto-dismiss timer.
local function _cleanup()
  if _timer then
    _timer:stop()
    _timer = nil
  end
  for _, hk in ipairs(_hotkeys) do
    hk:delete()
  end
  _hotkeys = {}
end

--- Withdraw the live notification if it is still showing.
local function _dismissNotification()
  if _notify then
    _notify:withdraw()
    _notify = nil
  end
end

--- Bind Option+D, Option+C, and/or Option+H while the cleanup/compress offer is live.
local function _bindCleanupKeys(dupCount, isConsoleLog, isHTML, originalBunxContent)
  -- Remove any previously registered keys before binding fresh ones.
  _cleanup()

  -- Option+Z / Cmd+Z  →  Undo npx -> bunx replacement
  if originalBunxContent then
    local function undoAction()
      _cleanup()
      _dismissNotification()
      _isSelfWrite = true
      hs.pasteboard.setContents(originalBunxContent)
      hs.alert.show("Reverted to `npx` ↩️")
    end

    local hkZ = hs.hotkey.bind({"alt"}, "Z", undoAction)
    table.insert(_hotkeys, hkZ)
    local hkCmdZ = hs.hotkey.bind({"cmd"}, "Z", undoAction)
    table.insert(_hotkeys, hkCmdZ)
  end

  -- Option+D  →  deduplicate clipboard in-place
  local hkD = nil
  if dupCount > 0 then
    hkD = hs.hotkey.bind({"alt"}, "D", function()
      _cleanup()
      _dismissNotification()
      hs.execute("LANG=en_US.UTF-8 pbpaste | awk '!seen[$0]++' | LANG=en_US.UTF-8 pbcopy")
      hs.alert.show("Clipboard Cleaned! ✨")
    end)
    table.insert(_hotkeys, hkD)
  end

  -- Option+C  →  compactify console logs
  local hkC = nil
  if isConsoleLog then
    hkC = hs.hotkey.bind({"alt"}, "C", function()
      _cleanup()
      _dismissNotification()
      -- ccompact reads from pbpaste and writes to pbcopy by default now
      hs.execute("/Users/matt/projects/console-compactifier/bin/ccompact")
      hs.alert.show("Logs Compactified! ✨")
    end)
    table.insert(_hotkeys, hkC)
  end

  -- Option+H  →  compress HTML
  local hkH = nil
  if isHTML then
    hkH = hs.hotkey.bind({"alt"}, "H", function()
      _cleanup()
      _dismissNotification()
      hs.execute("/Users/matt/projects/webpage-compressor/dist/compress-html.js")
      hs.alert.show("HTML Compressed! ✨")
    end)
    table.insert(_hotkeys, hkH)
  end

  -- Escape  →  cancel silently
  local hkEsc = hs.hotkey.bind({}, "escape", function()
    _cleanup()
    _dismissNotification()
  end)
  table.insert(_hotkeys, hkEsc)

  -- Auto-remove the hotkeys after 5 seconds of inactivity.
  _timer = hs.timer.doAfter(5, function()
    _cleanup()
    _dismissNotification()
  end)
end

-- ── Clipboard watcher callback ──────────────────────────────────────────────────

local function _onClipboardChange()
  if _isSelfWrite then
    _isSelfWrite = false
    return
  end

  local content = hs.pasteboard.readString()
  if not content then return end

  -- 1. Automatic npm/pnpm/npx -> bun/bunx replacement
  local originalContent = content
  local isBunxReplaced = false

  local function replaceCmd(target, replacement)
    local updated1, c1 = content:gsub("^" .. target .. "(%s+)", replacement .. "%1")
    local updated2, c2 = updated1:gsub("(%s)" .. target .. "(%s+)", "%1" .. replacement .. "%2")
    local updated3, c3 = updated2:gsub("^" .. target .. "$", replacement)
    local updated4, c4 = updated3:gsub("(%s)" .. target .. "$", "%1" .. replacement)
    
    if c1 > 0 or c2 > 0 or c3 > 0 or c4 > 0 then
      isBunxReplaced = true
      content = updated4
    end
  end

  replaceCmd("npx", "bunx")
  replaceCmd("npm%s+install", "bun install")
  replaceCmd("npm%s+i", "bun install")
  replaceCmd("pnpm%s+install", "bun install")
  replaceCmd("pnpm%s+i", "bun install")
  replaceCmd("npm%s+run", "bun run")
  replaceCmd("pnpm%s+run", "bun run")

  if isBunxReplaced then
    _isSelfWrite = true
    hs.pasteboard.setContents(content)
  end

  -- Check for console logs (stack trace signatures)
  local isConsoleLog = content:match("\n[ \t]+at ") or 
                       content:match("\n[ \t]+in ") or 
                       content:match("@ VM%d+") or 
                       content:match("\n[ \t]+%([^%)]+%)") or
                       content:match("\n[ \t]+%w+ %([^%)]+%)")

  -- Check for HTML content
  local lowerContent = content:lower()
  local isHTML = lowerContent:match("<html") or 
                 lowerContent:match("<body") or 
                 lowerContent:match("</div>") or 
                 lowerContent:match("</span>") or
                 lowerContent:match("<!doctype")

  -- Count duplicate lines via awk (ignores blank lines, NF guard).
  local raw, _, _, _ = hs.execute(
    "LANG=en_US.UTF-8 pbpaste | awk 'NF {if (seen[$0]++) d++} END {print +d}'"
  )

  local count = tonumber(raw and raw:match("%d+")) or 0
  if count == 0 and not isConsoleLog and not isHTML and not isBunxReplaced then return end

  -- Dismiss any previously shown notification before creating a new one.
  _dismissNotification()

  local title = isBunxReplaced and "Node ➔ Bun 👌" or "Clipboard Cleanup Available"
  local msg = {}

  if isBunxReplaced then
    table.insert(msg, "Swapped npm/pnpm/npx with bun (Opt+Z / Cmd+Z to undo).")
  end
  if count > 0 then
    table.insert(msg, string.format("%d duplicate line%s found (Opt+D).", count, count == 1 and "" or "s"))
  end
  if isConsoleLog then
    table.insert(msg, "Console logs detected (Opt+C to compactify).")
  end
  if isHTML then
    table.insert(msg, "HTML detected (Opt+H to compress).")
  end

  -- Show a passive, non-blocking macOS notification.
  _notify = hs.notify.new(nil, {
    title            = title,
    informativeText  = table.concat(msg, "\n") .. "\nPress Esc to dismiss.",
    autoWithdraw     = false,
    hasActionButton  = false,
  })
  _notify:send()

  if isBunxReplaced then
    hs.sound.getByName("Tink"):play()
  end

  -- Wire up the temporary hotkeys.
  _bindCleanupKeys(count, isConsoleLog, isHTML, isBunxReplaced and originalContent or nil)
end

-- ── Module initialisation ───────────────────────────────────────────────────────

--- Start the clipboard watcher. Called once from init.lua.
function M.start()
  activeWatchers.clipboardWatcher = hs.pasteboard.watcher.new(_onClipboardChange)
  activeWatchers.clipboardWatcher:start()
end

--- Stop the clipboard watcher and clean up all resources.
function M.stop()
  _cleanup()
  _dismissNotification()
  if activeWatchers.clipboardWatcher then
    activeWatchers.clipboardWatcher:stop()
    activeWatchers.clipboardWatcher = nil
  end
end

-- M.start()

return M