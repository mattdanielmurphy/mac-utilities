-- ~/.hammerspoon/modules/fade_skip.lua
-- Next/previous track media keys fade the song out quickly before skipping.
--
-- Catches the NX_SYSDEFINED media-key events (Mac keyboard F7/F9, Logitech
-- keyboard keys, the PS5 dashboard's posted keys) and swallows them. If Music
-- is playing, bin/fade-skip.applescript fades Music's own volume, skips and puts
-- it back (runs as a separate osascript so the tap never blocks). Otherwise it
-- fades the system output volume, skips through MediaRemote (nowplaying-cli),
-- and restores the volume.
--
-- Pressing again mid-fade skips at once. Holding a key no longer scrubs.
-- AirPods/Bluetooth headphone controls go straight to MediaRemote and never
-- reach an event tap, so they still skip instantly. M.log keeps the last 20
-- media-key presses (any media key) for checking which buttons arrive here.

-- Feel knobs (⌃⌥⌘T Tweaks panel); found by bin/tweaks scan, kept by prune.
local TWEAKS = {
  ["fade.seconds"] = { 0.4, min = 0.05, max = 3, step = 0.05, note = "Seconds the fade-out takes" },
  ["fallback.fadeSteps"] = { 12, min = 3, max = 40, step = 1, note = "Number of volume steps in the system-volume fade" },
  ["fallback.restoreDelay"] = { 0.4, min = 0, max = 2, step = 0.05, note = "Seconds to wait after skipping before restoring system volume" },
}
local T = hs and type(hs.reload) == "function" and require("modules.tweaks").open{ app = "Fade Out Before Skipping Tracks",
  file = require("modules.tweaks").dir .. "/fade_skip.json", knobs = TWEAKS }
  or function(k) return TWEAKS[k][1] end

local M = {
  id = "fade_skip",
  name = "Fade Out Before Skipping Tracks",
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local CFG = {
  fadeSecs = T("fade.seconds"),      -- length of the fade-out
  sysSteps = T("fallback.fadeSteps"),       -- steps for the system-volume fallback fade
  sysRestoreDelay = T("fallback.restoreDelay"), -- system fallback: wait after skipping before turning the
                         -- volume back up (browsers take a moment to drop the old track)
}

local SKIP = { NEXT = "next", FAST = "next", PREVIOUS = "prev", REWIND = "prev" }
local SCRIPT = hs.configdir .. "/bin/fade-skip.applescript"
local OSASCRIPT = "/usr/bin/osascript"
local NOWPLAYING = "/usr/local/bin/nowplaying-cli"

M.CFG = CFG
M.log = {}

-- One fade at a time: a running Music task, or a system-volume fade.
local cur = nil

local function remember(entry)
  entry.at = os.date("%H:%M:%S")
  table.insert(M.log, 1, entry)
  M.log[21] = nil
end

local function run(path, args, done)
  local t = hs.task.new(path, done or function() end, args)
  t:start()
  return t
end

local function mediaRemote(dir)
  run(NOWPLAYING, { dir == "prev" and "previous" or "next" })
end

local function musicNow(dir, vol)
  local cmd = (dir == "prev") and "back track" or "next track"
  local restore = vol and ("\nset sound volume to " .. vol) or ""
  run(OSASCRIPT, { "-e", 'tell application "Music"\n' .. cmd .. restore .. "\nend tell" })
end

local function systemFade(dir)
  local dev = hs.audiodevice.defaultOutputDevice()
  local vol = dev and dev:outputVolume()
  if not vol or vol <= 0 or dev:outputMuted() then
    mediaRemote(dir)
    return
  end
  local job = { kind = "system", dev = dev, vol = vol, step = 0 }
  cur = job
  job.timer = hs.timer.doEvery(CFG.fadeSecs / CFG.sysSteps, function()
    job.step = job.step + 1
    local k = 1 - job.step / CFG.sysSteps
    dev:setOutputVolume(vol * k * k)
    if job.step >= CFG.sysSteps then
      job.timer:stop()
      mediaRemote(dir)
      job.restore = hs.timer.doAfter(CFG.sysRestoreDelay, function()
        dev:setOutputVolume(vol)
        if cur == job then cur = nil end
      end)
    end
  end)
end

-- Cut a running fade short: skip now and put the volume back.
local function finishNow(job, dir)
  cur = nil
  if job.kind == "music" then
    job.cancelled = true
    if job.task:isRunning() then job.task:terminate() end
    musicNow(dir, job.vol)
  else
    if job.timer then job.timer:stop() end
    if job.restore then job.restore:stop() end
    mediaRemote(dir)
    job.dev:setOutputVolume(job.vol)
  end
end

function M.skip(dir)
  if cur then
    finishNow(cur, dir)
    return
  end
  if not hs.application.applicationsForBundleID("com.apple.Music")[1] then -- get() would scan all windows if Music is closed
    systemFade(dir)
    return
  end
  local job = { kind = "music" }
  cur = job
  -- With a stream callback, hs.task hands output only to the stream, so
  -- collect it there; the exit callback's own stdout arg comes back empty.
  job.out = ""
  job.task = hs.task.new(OSASCRIPT, function(code, out)
    out = job.out .. (out or "")
    if cur == job then cur = nil end
    if job.cancelled then return end
    if code ~= 0 then
      -- Script failed (permission, Music busy): still skip, and undo any fade.
      print("fade_skip: osascript exit " .. tostring(code))
      musicNow(dir, job.vol)
    elseif out:match("none") then
      systemFade(dir)
    end
  end, function(_, out, err)
    if out then job.out = job.out .. out end
    local v = err and err:match("vol (%d+)")
    if v then job.vol = tonumber(v) end
    return true
  end, { SCRIPT, dir, tostring(CFG.fadeSecs) })
  job.task:start()
end

function M.start()
  M.stop()
  activeWatchers.fadeSkipTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
    local ok, k = pcall(e.systemKey, e)
    if not ok or type(k) ~= "table" or not k.key then return false end
    local dir = SKIP[k.key]
    if k.down and not k["repeat"] then remember({ key = k.key, handled = dir ~= nil }) end
    if not dir then return false end
    if k.down and not k["repeat"] then M.skip(dir) end
    return true
  end)
  activeWatchers.fadeSkipTap:start()
end

function M.stop()
  if activeWatchers.fadeSkipTap then
    activeWatchers.fadeSkipTap:stop()
    activeWatchers.fadeSkipTap = nil
  end
end

return M
