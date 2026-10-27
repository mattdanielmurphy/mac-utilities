# MDMA: Matt Daniel Murphy's Appothecary

Matt's Mac utilities, built on Hammerspoon. This is a list of the utilities from Matt's Mac that also run on yours. Every one starts **off**. In the ⚙︎ menu bar icon, hover over one to see what it does and click it to switch it on or off. **What Do These Do?** in the same menu shows this page.

**Ask Claude about them.** Something like "Read ~/.hammerspoon/UTILITIES.md and tell me which of these I'd use." Claude can open `~/.hammerspoon/modules/<file>.lua` for the full details of any one.

**Using Claude Code?** Tell it: "Read ~/.hammerspoon/CLAUDE_SETUP.md and do it." It sets up the Claude tools below (take-control banner, toasts) so your Claude uses them.

**Voice calls that save themselves.** `voice/` is a connector for Claude's voice chat: every call is saved as a note on your Mac, and voice Claude can search past calls and read your files. Tell Claude Code: "Read ~/.hammerspoon/voice/SETUP.md and do it." (Needs a paid Claude plan and a free Tailscale account.)

**Updates arrive on their own.** Your Mac checks for updates every 15 minutes and whenever it wakes, and Hammerspoon reloads. ⚙︎ > Update Now pulls straight away. If you edit these files yourself, updates stop (the pull won't overwrite your edits), so keep your own changes in a separate file.

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
**Song Key HUD.** While music plays, a small pill shows the song's key, looked up on Hooktheory. It listens first and stays away for speech (podcasts, narrated videos, reels). Click it, or press Esc in its first few seconds, to hide it until the next song; it also fades by itself after a while. The ↗ corner opens the Hooktheory page. Needs `brew install nowplaying-cli`.

### modules.otp_copy
**2FA Code Auto-Copy.** When a verification code arrives by text (Messages) or email (Mail), it goes straight to your clipboard and a small pill shows it in the bottom-left corner. Google's "G-123456" codes copy as just the digits. Clipboard managers that respect hidden items won't save the code, and it's wiped from the clipboard after 2 minutes. Needs Full Disk Access for Hammerspoon (System Settings › Privacy & Security › Full Disk Access). Replaces apps like MessAuto or 2FHey; switch those off so codes don't get copied twice.

### modules.gif_picker
**GIF Picker (⌃⌥⌘G).** A window of GIFs that aren't lame. **Curated** mixes thousands of GIFs hand-collected by people on Are.na (de-duplicated, reshuffled daily, ⤮ for a new mix); **Reddit best** is the all-time top of r/HighQualityGifs and r/reactiongifs; **Starred** is your own stash (hover a GIF, click ☆). Type and press Return to search all of it plus Reddit's GIF subreddits. Click a GIF to copy it, then ⌘V into Messages, Slack or Discord (it stays animated). No account or API key. Channels, subreddits, tile size and loading speed are in the Tweaks panel (⌃⌥⌘T).

### modules.tv_resync
**TV Re-sync.** For a Mac driving a TV through a USB-C hub with the lid shut: when the TV comes back on showing "no signal", this does what opening the lid would (blanks the display for ~4 seconds and wakes it). It fires on its own when the display disappears, on your first touch after 10 minutes idle (works at the lock screen), and after the Mac wakes, all only with the lid shut. ⌃⌥R re-syncs any time. To limit it to one screen, set `display.nameContains` (e.g. `TV`) in `~/.hammerspoon/tweaks/tv_resync.json`. From Tyler's tvresync; if you still run that app, quit it so they don't both re-sync.

### modules.claude_control
**Claude Take-Control Banner.** Before Claude types, clicks or switches apps on your Mac, it asks first: an orange banner says what it wants to do and why, and it waits its turn behind any other Claude. Esc means "not now", Esc twice or Stop ends that task. Small changes (opening a file, play/pause) get a small pill instead. Needs Claude set up to use it: see `CLAUDE_SETUP.md`.

### modules.claude_notify
**Claude Toasts.** Quiet corner toasts when Claude finishes something or needs you, tinted by kind (green done, amber needs you, red error). Click one to open the thread. Claude sends them with `~/.hammerspoon/bin/claude-notify "Title" "Body"`; `CLAUDE_SETUP.md` teaches it when.

### modules.claude_cmd_k
**Claude Cmd-K → Project Filter.** In the Claude app, ⌘K opens the palette already filtered to the current project. ⌘⇧K gives the plain palette. Change or clear what it types with `palette.filter` in `~/.hammerspoon/tweaks/claude_cmd_k.json`.

### modules.quote_comment
**Quote + Dictate for Claude (⌥R).** Highlight text anywhere and press ⌥R: it lands in Claude's message box as a quote and dictation starts. Talk, press Return, and it queues; repeat for more quotes. Plain Return in an empty box sends the whole batch as one message. ⌥⇧R queues a quote with no comment.
