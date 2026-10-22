# Matt's Mac utilities

These are small Mac utilities built on [Hammerspoon](https://www.hammerspoon.org) (free, open source): click-lock, break reminders, a clipboard cleaner, music key and chord overlays, and more. **[UTILITIES.md](UTILITIES.md)** lists each one and what it does.

Once installed, they live behind the ⚙︎ icon in the menu bar. Everything starts **off**. Hover over a utility to see what it does, click it to switch it on, and pick **What Do These Do?** to read the full list. Updates install themselves every hour.

## Install

Paste this into Terminal (or ask Claude to "install the utilities from this repo"):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mattdanielmurphy/mac-utilities/main/install.sh)
```

When it finishes, switch on **Hammerspoon** in the System Settings window it opens (Privacy & Security > Accessibility). macOS doesn't let a script do that step.

## For Claude (installing or explaining this for someone)

- **To install:** run the install command above, then tell the person to switch on Hammerspoon under Accessibility. [install.sh](install.sh) installs Hammerspoon (with Homebrew, or the GitHub release), moves any existing `~/.hammerspoon` to `~/.hammerspoon.bak-<date>`, clones this repo into `~/.hammerspoon`, and writes `~/.hammerspoon/profile` containing `shared`.
- **To explain a utility:** read [UTILITIES.md](UTILITIES.md), then `modules/<name>.lua` for details such as exact keys and timings. Only the modules listed in UTILITIES.md are included and load.
- **To switch one on or off:** the person clicks it in the ⚙︎ menu. The setting is remembered across restarts.
- **Updates:** the Mac runs `git pull --ff-only origin main` every hour, and Hammerspoon reloads itself when files change. ⚙︎ > Update Now pulls straight away. Don't edit the files in `~/.hammerspoon`: local edits make the pull refuse, which stops updates. Put personal additions in a separate Hammerspoon file instead.
- **To uninstall:** quit Hammerspoon, move `~/.hammerspoon` to the Trash (restore a `.bak-` folder if there is one), and delete Hammerspoon.app if it isn't wanted.

## For Matt

This repo is a scanned export of the shareable part of the private hammerspoon-config, and it's built for me: no feature requests. `bin/ship-public` publishes it. To share another utility, add its path to `SHAREABLE` in modules/suite.lua and a `### modules.<name>` section to UTILITIES.md.
