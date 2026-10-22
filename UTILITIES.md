# Matt's Mac utilities

This is a list of the Hammerspoon utilities from Matt's Mac that also run on yours. Every one starts **off**. In the ⚙︎ menu bar icon, hover over one to see what it does and click it to switch it on or off. **What Do These Do?** in the same menu shows this page.

**Ask Claude about them.** Something like "Read ~/.hammerspoon/UTILITIES.md and tell me which of these I'd use." Claude can open `~/.hammerspoon/modules/<file>.lua` for the full details of any one.

**Updates arrive on their own.** Your Mac pulls updates once an hour and Hammerspoon reloads. ⚙︎ > Update Now pulls straight away. If you edit these files yourself, updates stop (the pull won't overwrite your edits), so keep your own changes in a separate file.

## Utilities

<!-- One `###` per module path in modules/suite.lua SHAREABLE. tests/suite_test.lua checks they match. -->

### modules.click_lock
**Mouse Click-Lock.** ⌘⌥-click holds the mouse button down so you can drag without holding it. Click again or press Escape to let go.

### modules.clipboard
**Clipboard Cleaner.** When you copy text with duplicate lines, a small prompt pops up for 5 seconds. ⌥D removes the duplicates and ⌘Z undoes it. Its ⌥C and ⌥H buttons call two of Matt's own tools that aren't on your Mac, so they do nothing.

### modules.eye_breaks
**Eye & Break Reminders.** Every 20 minutes of use you get a small "look 20 ft away for 20 s" alert. After 3 hours straight it asks for a real break, and after 6 hours it dims the screen until you step away. Being idle resets the clock.

### modules.fade_skip
**Fade Out Before Skipping.** The next and previous media keys fade the song out quickly before they skip. It works with Apple Music on its own. Other players need `brew install nowplaying-cli`.

### modules.wake_mute
**Mute After Long Sleep.** Mutes your speakers when the Mac wakes from more than 10 minutes asleep or locked, so it never blasts audio in a quiet room. Short breaks don't trigger it.

### modules.selection_wrap
**Selection Wrapping.** Select text and type `(`, `[`, `{`, a quote or a backtick, and it wraps the selection instead of replacing it, like a code editor does.

### modules.right_command_raycast
**Right ⌘ → Raycast.** Hold the right ⌘ key and start typing: Raycast (or another launcher you pick in its settings) opens with what you typed. Escape cancels. Needs Raycast.

### modules.chrome_cmd_e
**Chrome ⌘E → ⌘⌥G.** In Google Chrome, ⌘E sends ⌘⌥G instead. It's niche, so leave it off unless you know you want it.

### modules.keybindings
**CloudMounter Popup Guard.** Closes CloudMounter's "upgrade" nag window automatically. Only useful if you use CloudMounter.

### modules.input_guard
**Runaway Typing Guard.** If a script or an AI agent starts spamming keystrokes (lots of Returns or text in a few seconds), it blocks scripted keys until they stop. Your real typing is never affected. Handy if you let Claude drive your Mac.

### modules.clamshell_guard
**Bag Overheating Guard.** On battery with the lid shut, if the Mac stays busy (CPU above 20%) for 3 minutes in your bag, it forces sleep to save the battery. Its other part texts Matt's own phone, so it does nothing on your Mac.

### modules.logic_editor
**Logic Symbol Editor.** ⌃⌘L opens a small editor for writing logic formulas (∧ ∨ ¬ → ↔ ∀ ∃) with shortcuts and a cheat sheet, then pastes the result into your app. It was made for a logic course.

### modules.piano_hud
**Piano Chord HUD.** While a MIDI keyboard is plugged in, a small overlay shows the chord you're playing. Click it for the chord's intervals, keys and modes. It also logs every note to `~/Documents/Piano Log/`.

### modules.song_key
**Song Key HUD.** While music plays, a small pill shows the song's key, looked up on Hooktheory. Click it to open the Hooktheory page. Needs `brew install nowplaying-cli`.
