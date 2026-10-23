# Set up the voice connector ("My Mac")

Instructions for Claude (Claude Code: desktop app or CLI). The user asked you to set up MDMA's voice connector on this Mac. When it's done, Claude's voice chat (claude.ai / Claude app) can save every call as a note on this Mac, search past calls and read files here.

What it is: a small server (`~/.hammerspoon/voice/server.ts`) that runs in the background and is published to the internet by [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) at a long secret URL. claude.ai talks to it as a custom connector. It is read-only except for writing call notes, only reads inside the home folder, and refuses secret files (`.env`, keys, `.ssh`, passwords, tokens).

Needs: a paid Claude plan (custom connectors), a free Tailscale account, and the Mac awake when calls happen. Safe to run again.

Explain the above to the user in a few lines and get their OK before step 1.

## 1. Check MDMA, Bun

- `~/.hammerspoon/voice/server.ts` must exist. If not, install MDMA first: `curl -fsSL https://raw.githubusercontent.com/mattdanielmurphy/mac-utilities/main/install.sh | bash`
- `bun --version`. If missing: `curl -fsSL https://bun.sh/install | bash`

## 2. Tailscale with Funnel

- If `tailscale status` fails: install it (`brew install --cask tailscale`, or from the Mac App Store), open it, and have the user sign in (their own account; free).
- Run `tailscale funnel status`. If it already publishes something on port 443, stop and ask the user: this setup would replace it.
- The first `tailscale funnel` run may print a link to turn on Funnel for their tailnet. Give the user that link to click, then carry on.

## 3. Ask two things, save them

Ask the user their first name and where call notes should go (default `~/Documents/Voice calls`; if they use Obsidian, a folder inside their vault is better). Write `~/.config/mdma-voice/config.json`:

```json
{ "name": "<their first name>", "notes": "<folder, ~ is fine>" }
```

## 4. Install

With the user's OK (it replaces their clipboard with the connector URL): `~/.hammerspoon/voice/install.sh`

It installs packages, creates the secret token in `~/.config/mdma-voice/token`, starts the server at login (launchd `com.mdma.voice-connector`), turns Funnel on and copies the connector URL. Never print or read the token or the URL into the chat; it's the only key.

Check: `curl -s http://127.0.0.1:8777/health` prints `ok`.

## 5. The user adds it in claude.ai (you can't do this part)

Tell them, one step at a time:

1. [claude.ai](https://claude.ai) → Settings → Connectors → **Add custom connector**. Name: `My Mac`. URL: paste (it's on the clipboard). No OAuth. Save.
2. Settings → Profile → "What personal preferences should Claude consider?" → add this line. It's what makes every call save itself:

   > In voice chats, at the end of every call (or when I say bye / that's it), run the My Mac connector's save_call before you finish.

3. Start a voice chat, say a sentence or two, then "that's it, bye". A note should appear in their notes folder within seconds (and an MDMA toast, if Claude Toasts is on).

## Notes

- Uninstall: `~/.hammerspoon/voice/install.sh uninstall` (stops it and turns Funnel off), then remove the connector in claude.ai.
- New URL (if it ever leaked): move `~/.config/mdma-voice/token` to the Trash, run `install.sh` again, and update the connector's URL in claude.ai.
- Logs: `~/.config/mdma-voice/connector.log` and `launchd.log`.
- Calls only save while the Mac is awake and online. A call that ends without save_call is not saved; its transcript is still in the user's claude.ai history.
- If [QMD](https://github.com/tobi/qmd) is installed, search_notes uses it (every note it indexes); otherwise it uses Spotlight over the notes folder.
