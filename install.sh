#!/bin/zsh
# Builds gd88bridge and installs it as a per-user background service (LaunchAgent).
#
#   ./install.sh                        auto-detects a paired GD-88 / PeriPage printer
#   ./install.sh --printer 01-23-45-67-89-ab
#   ./install.sh --raw-port 9100        any gd88bridge options are passed through (see README)
#
# Installs to:  ~/Library/Application Support/GD88Bridge/GD88Bridge.app
#               ~/Library/LaunchAgents/local.gd88-bridge.plist
# Log:          ~/Library/Logs/gd88-bridge.log
set -euo pipefail
cd "${0:A:h}"

VERSION="1.0.0"
LABEL="local.gd88-bridge"
DEST="$HOME/Library/Application Support/GD88Bridge"
APP="$DEST/GD88Bridge.app"
BIN="$APP/Contents/MacOS/gd88bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/gd88-bridge.log"
DOMAIN="gui/$(id -u)"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Install Apple's Command Line Tools first:  xcode-select --install"
  exit 1
fi

echo "==> Building gd88bridge $VERSION"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -o "$BUILD/gd88bridge" src/*.swift -framework IOBluetooth -framework CoreBluetooth

echo "==> Installing $APP"
mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents" "${LOG:h}"
cp "$BUILD/gd88bridge" "$BIN"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$LABEL</string>
	<key>CFBundleName</key><string>GD88 Bridge</string>
	<key>CFBundleExecutable</key><string>gd88bridge</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSBluetoothAlwaysUsageDescription</key><string>Sends print jobs to the GD-88 thermal printer over Bluetooth.</string>
</dict>
</plist>
EOF
# Ad-hoc signature: macOS needs a signed bundle to remember the Bluetooth permission.
codesign --force --sign - --identifier "$LABEL" "$APP"

xml() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; print -r -- "$s"; }
args_xml="		<string>$(xml "$BIN")</string>"
for a in "$@"; do args_xml+=$'\n'"		<string>$(xml "$a")</string>"; done

old_plist=""
[[ -f "$PLIST" ]] && old_plist="$(cat "$PLIST")"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
$args_xml
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<!-- 077: the log and spooled print jobs are readable by you only -->
	<key>Umask</key>
	<integer>63</integer>
	<key>StandardOutPath</key>
	<string>$(xml "$LOG")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$LOG")</string>
</dict>
</plist>
EOF
new_plist="$(cat "$PLIST")"
touch "$LOG" && chmod 600 "$LOG"     # a log from an older install may still be world-readable

echo "==> Starting the background service ($LABEL)"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  if [[ "$old_plist" == "$new_plist" ]]; then
    launchctl kickstart -k "$DOMAIN/$LABEL"          # same settings: just restart the new build
  else
    launchctl bootout "$DOMAIN/$LABEL" || true       # settings changed: reload the service definition
    launchctl bootstrap "$DOMAIN" "$PLIST"
  fi
else
  launchctl bootstrap "$DOMAIN" "$PLIST"
fi

sleep 2
cat <<EOF

Installed. Next:
  1. If macOS asks "GD88 Bridge would like to use Bluetooth", click Allow.
     (It asks again after every reinstall, because each build has a new signature.)
  2. Open System Settings › Printers & Scanners › Add Printer…, select
     "HZTZ GD-88 (Bluetooth)" and click Add.

Status page: http://localhost:8631/      Log: $LOG
EOF
tail -4 "$LOG" 2>/dev/null || true
