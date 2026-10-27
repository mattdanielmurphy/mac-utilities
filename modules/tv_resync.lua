-- modules/tv_resync.lua
-- TV Re-sync: a TV behind a USB-C hub that comes back on showing "no signal" picks the
-- Mac up again once the display is slept and woken, which is what opening the lid does.
-- This does it for you, with the lid shut, at the moments the TV is likely stuck:
--
--   display vanished   re-sync every retrySeconds until it's back, the lid opens, or 30 min
--   first touch        first key/trackpad input after idleMinutes of none (works at the lock screen)
--   after wake         once, a few seconds after the Mac wakes
--   ⌃⌥R                re-sync now (any time; not at the lock screen)
--
-- Many hubs keep telling macOS the TV is attached even while it's off, so the Mac can't
-- see it come back; that's why it aims at moments instead of watching the TV.
-- Each re-sync blanks the display ~4 s; it only fires while the TV likely shows nothing.
-- Ported from Tyler's tvresync (github.com/tylermurphysound/tvresync).

local M = {
  id = "tv_resync",
  name = "TV Re-sync (⌃⌥R)",
  defaultEnabled = true,
}

_G.activeWatchers = _G.activeWatchers or {}
local W = _G.activeWatchers
local T

local MISSING_GIVE_UP = 30 * 60

-- ── Decision logic (pure; tested in tests/tv_resync_test.lua) ──────────────────
-- s: state table (mutated). i: { now, lid, shown, idle, cfg }. Returns a reason or nil.
function M.decide(s, i)
  local cfg, reason = i.cfg, nil
  local prevIdle = s.prevIdle or 0
  s.prevIdle = i.idle
  if s.missingSince then
    if i.shown then s.missingSince = nil
    elseif not i.lid then s.missingSince = nil
    elseif i.now - s.missingSince > MISSING_GIVE_UP then s.missingSince = nil
    elseif i.now - (s.lastResync or -math.huge) >= cfg.sleepSeconds + cfg.retrySeconds then
      reason = "display missing, retrying"
    end
  elseif cfg.onDisconnect and i.lid and not i.shown and s.lastSeen then
    s.missingSince = i.now
    reason = s.lastSeen .. " disappeared"
  elseif cfg.onFirstTouch and i.lid and i.shown and prevIdle >= cfg.idleMinutes * 60
      and i.idle < 10 and i.now - (s.lastResync or -math.huge) > 60 then
    reason = string.format("first touch after %d min idle", math.floor(prevIdle / 60))
  end
  if i.shown then s.lastSeen = i.shown elseif not s.missingSince then s.lastSeen = nil end
  return reason
end

-- ── Mac side ───────────────────────────────────────────────────────────────────

local state = {}
local busy = false

local function cfg()
  return {
    onDisconnect = T("trigger.onDisconnect"), onFirstTouch = T("trigger.onFirstTouch"),
    onWake = T("trigger.onWake"), idleMinutes = T("timing.idleMinutes"),
    retrySeconds = T("timing.retrySeconds"), sleepSeconds = T("timing.sleepSeconds"),
  }
end

-- With an external display attached, a shut lid takes the built-in screen offline,
-- so "no built-in screen" means the lid is shut. No ioreg call every 2 s.
local function screens()
  local lid, shown = true, nil
  local filter = (T("display.nameContains") or ""):lower()
  for _, s in ipairs(hs.screen.allScreens()) do
    local name = s:name() or ""
    if name:find("Built%-in") or name:find("Color LCD") then lid = false
    elseif not shown and (filter == "" or name:lower():find(filter, 1, true)) then shown = name end
  end
  return lid, shown
end

function M.resync(reason)
  if busy then return end
  busy, state.lastResync = true, hs.timer.secondsSinceEpoch()
  print("📺 [tv_resync] re-sync (" .. reason .. ")")
  W.tvResyncTask = hs.task.new("/usr/bin/pmset", nil, { "displaysleepnow" })
  W.tvResyncTask:start()
  W.tvResyncWake = hs.timer.doAfter(T("timing.sleepSeconds"), function()
    hs.caffeinate.declareUserActivity() -- wakes the display, like a key press
    W.tvResyncDone = hs.timer.doAfter(2, function() busy = false end)
  end)
end

local function poll()
  local lid, shown = screens()
  local reason = M.decide(state, { now = hs.timer.secondsSinceEpoch(), lid = lid, shown = shown,
    idle = hs.host.idleTime(), cfg = cfg() })
  if reason then M.resync(reason) end
end

function M.start()
  M.stop()
  local tweaks = require("modules.tweaks")
  T = T or tweaks.open{
    app = "TV Re-sync",
    file = tweaks.dir .. "/tv_resync.json",
    knobs = {
      ["timing.pollSeconds"] = { 2, min = 0.5, max = 10, step = 0.5, note = "Seconds between idle/screen state checks" },
      ["timing.wakeDelaySeconds"] = { 5, min = 1, max = 20, step = 1, note = "Seconds to wait after wake before checking screens" },
      ["trigger.onDisconnect"] = { true, note = "Re-sync while the display is missing (lid shut)" },
      ["trigger.onFirstTouch"] = { true, note = "Re-sync on the first touch after a long idle (lid shut)" },
      ["trigger.onWake"] = { true, note = "Re-sync once after the Mac wakes (lid shut)" },
      ["timing.idleMinutes"] = { 10, min = 1, max = 120, step = 1, note = "Idle minutes before a touch counts as first touch" },
      ["timing.retrySeconds"] = { 10, min = 5, max = 120, step = 1, note = "Gap between re-syncs while the display is missing" },
      ["timing.sleepSeconds"] = { 4, min = 1, max = 15, step = 0.5, note = "Seconds the display stays off during a re-sync" },
      ["display.nameContains"] = { "", note = "Only re-sync displays whose name contains this (e.g. TV); empty = any external" },
    },
  }
  state = { prevIdle = hs.host.idleTime() }
  W.tvResyncPoll = hs.timer.doEvery(T("timing.pollSeconds"), poll)
  W.tvResyncHotkey = hs.hotkey.bind({ "ctrl", "alt" }, "R", function() M.resync("hotkey") end)
  W.tvResyncSleep = hs.caffeinate.watcher.new(function(event)
    if event ~= hs.caffeinate.watcher.systemDidWake or not T("trigger.onWake") then return end
    W.tvResyncAfterWake = hs.timer.doAfter(T("timing.wakeDelaySeconds"), function()
      local lid, shown = screens()
      if lid and shown and hs.timer.secondsSinceEpoch() - (state.lastResync or 0) > 30 then
        M.resync("after wake, " .. shown)
      end
    end)
  end):start()
end

function M.stop()
  for _, k in ipairs({ "tvResyncPoll", "tvResyncHotkey", "tvResyncSleep", "tvResyncAfterWake", "tvResyncWake", "tvResyncDone" }) do
    local o = W[k]
    if o then
      if o.delete and not o.stop then o:delete() else o:stop() end -- hotkeys delete, timers/watchers stop
      W[k] = nil
    end
  end
  busy = false
end

return M
