-- Fade Music out, skip, and put the volume back. Run by modules/fade_skip.lua:
--   osascript fade-skip.applescript next|prev <fadeSeconds>
-- Logs "vol <n>" to stderr before fading so Hammerspoon can restore the volume
-- if a second press cuts the fade short. Returns "skipped", or "none" when
-- Music isn't playing (Hammerspoon then falls back to a system-volume fade).
on run argv
	set dir to item 1 of argv
	set fadeSecs to (item 2 of argv) as real
	if application "Music" is not running then return "none"
	tell application "Music"
		if player state is not playing then return "none"
		set v to sound volume
		log "vol " & v
		set steps to 12
		repeat with i from 1 to steps
			-- Squared curve: drops fast at first, so the fade sounds even.
			set k to 1 - (i / steps)
			set sound volume to round (v * k * k)
			delay fadeSecs / steps
		end repeat
		if dir is "prev" then
			back track -- same as the key: restart the song, or go back if near its start
		else
			next track
		end if
		-- Let the old track's buffered audio drain before turning it back up.
		delay 0.15
		set sound volume to v
	end tell
	return "skipped"
end run
