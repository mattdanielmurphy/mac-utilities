# Set up Claude for MDMA

Instructions for Claude (Claude Code: desktop app or CLI). The user asked you to set up MDMA's Claude tools on this Mac. Do these steps, then tell them in a few lines what changed. Safe to run again: it replaces its own block instead of adding a second one.

## 1. Check MDMA is installed

`~/.hammerspoon/profile` should say `shared`, and Hammerspoon should be running. If not, install MDMA first:

    curl -fsSL https://raw.githubusercontent.com/mattdanielmurphy/mac-utilities/main/install.sh | bash

## 2. Add the rules block to `~/.claude/CLAUDE.md`

Create the file if it's missing. If it already has a block between `<!-- MDMA:start -->` and `<!-- MDMA:end -->`, replace that block; otherwise append this one. Don't touch anything else in the file.

```markdown
<!-- MDMA:start -->
## MDMA tools on this Mac (from CLAUDE_SETUP.md; re-run it to update)
- **Ask before touching the screen.** Before any synthetic keyboard, mouse or app input on this Mac (typing, clicking, switching or opening apps, revealing files, play/pause, volume), including running automation you built, run `~/.hammerspoon/bin/claude-control ask "<what and why>" 3`. Exit 0 prints `granted <ticket>`: go, then run `~/.hammerspoon/bin/claude-control done <ticket>` right after. Exit 1 (Esc / "not now"): don't ask again; tell the user what you need and wait. Exit 3 (Stop): end the whole task and report what's left. Add `--light` for small changes (opening a file or app, focus, play/pause, volume); plain `ask` for typing, clicking or moving the mouse. In a project thread, add `--thread <cmsg_… id>` so the banner links back to you.
- **Toast when done or blocked.** When you finish a task that took more than a minute or two, or you need the user, run `~/.hammerspoon/bin/claude-notify "<short title>" "<one line>" --kind done|needs|error`. Add `--url <link>` to open something when they click it. Don't toast for quick replies.
<!-- MDMA:end -->
```

## 3. Turn the tools on

Each starts off. Turn on the ones the user wants (ask if unsure; the first two are the point of this setup):

    hs -c 'local MM = require("modules.module_manager"); for _, id in ipairs({"claude_control", "claude_notify", "claude_cmd_k", "quote_comment"}) do MM.setEnabled(id, true) end'

If `hs` isn't found, ask the user to tick them in the ⚙︎ menu bar icon (Claude & AI).

## 4. Show it works

With the user's OK (it shows a banner on their screen): `~/.hammerspoon/bin/claude-control ask "Testing the take-control banner" 3`, then `done` with the ticket it prints. Then `~/.hammerspoon/bin/claude-notify "MDMA is set up" "Claude will ask before taking control" --kind done`.

## Notes

- Quote + Dictate needs Xcode's command line tools the first time (`xcode-select --install`) to build its small microphone helper.
- Everything updates on its own; re-run this file after an update that changes it.
