#!/bin/zsh
# Stops and removes gd88bridge and the printer queues that use it.
#
#   ./uninstall.sh           remove the service, the app and the bridge's print queues
#   ./uninstall.sh --purge   also delete its settings (printer UUID), log and spool folder
set -uo pipefail

LABEL="local.gd88-bridge"
DEST="$HOME/Library/Application Support/GD88Bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/gd88-bridge.log"
SPOOL="$HOME/Library/Caches/GD88Bridge"

echo "==> Stopping the background service"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL" || echo "$LABEL was not running"
rm -f "$PLIST"
rm -rf "$DEST/GD88Bridge.app"

echo "==> Removing print queues that point to the bridge"
lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\): \(.*\)$/\1 \2/p' | while read -r queue uri; do
  case "$uri" in
    *localhost:8631*|*127.0.0.1:8631*|*gd88-bridge.local*|dnssd://HZTZ%20GD-88*)
      lpadmin -x "$queue" && echo "removed queue $queue ($uri)" ;;
    socket://127.0.0.1:9100*|socket://localhost:9100*)
      echo "kept queue $queue ($uri): it uses the vendor driver; remove it with: lpadmin -x $queue" ;;
  esac
done

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$DEST" "$SPOOL" "$LOG"
  echo "==> Deleted settings, spool folder and log"
else
  echo "==> Kept $DEST (printer UUID) and $LOG; run with --purge to delete them"
fi
echo "Done."
