#!/bin/zsh
# Install the MDMA voice connector: an always-on launchd agent, published by Tailscale Funnel.
#   ./install.sh             install deps, create the token, start, publish, copy the URL
#   ./install.sh uninstall   stop, unpublish, move the plist to ~/.Trash
# NO_FUNNEL=1 skips Tailscale (local testing).
set -e
LABEL=com.mdma.voice-connector
PLIST=~/Library/LaunchAgents/$LABEL.plist
DIR=${0:A:h}
PORT=${PORT:-8777}
LOG=~/.config/mdma-voice/launchd.log
TS=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
BUN=$(command -v bun || echo ~/.bun/bin/bun)

if [[ $1 == uninstall ]]; then
  launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
  [[ -z $NO_FUNNEL ]] && $TS funnel --https=443 off 2>/dev/null || true
  [[ -f $PLIST ]] && mv $PLIST ~/.Trash/
  echo "uninstalled"; exit 0
fi

[[ -x $BUN ]] || { echo "Bun is missing: curl -fsSL https://bun.sh/install | bash"; exit 1; }
if [[ -z $NO_FUNNEL ]] && ! $TS status >/dev/null 2>&1; then
  echo "Tailscale isn't installed or signed in; see SETUP.md step 2"; exit 1
fi
(cd $DIR && $BUN install --silent)
mkdir -p ${LOG:h}
cat > $PLIST <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BUN</string><string>server.ts</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key>
  <dict><key>PORT</key><string>$PORT</string><key>HOME</key><string>$HOME</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PL
if [[ -z $NO_FUNNEL ]]; then
  (cd $DIR && $BUN server.ts --init)
  $TS funnel --bg $PORT
else
  (cd $DIR && $BUN -e 'import{mkdirSync,writeFileSync,existsSync}from"fs";import{CONFIG_DIR}from"./server.ts";mkdirSync(CONFIG_DIR,{recursive:true});const f=CONFIG_DIR+"/token";existsSync(f)||writeFileSync(f,crypto.randomUUID().replaceAll("-","")+"\n",{mode:0o600})')
fi
launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$UID $PLIST
launchctl kickstart gui/$UID/$LABEL  # RunAtLoad alone sometimes waits
echo "installed $LABEL on 127.0.0.1:$PORT"
