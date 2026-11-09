#!/bin/zsh
# Builds gd88bridge and runs every check that does NOT print:
#   1. unit tests (tests/*.swift, built with swiftc together with src/ minus main.swift)
#   2. offline self-test (raster decoders vs macOS's own CUPS filters, trimming, and byte-exact
#      comparison with the vendor driver if it happens to be installed)
#   3. CUPS's IPP Everywhere conformance suite against a DRY-RUN copy on a private test port
#
# The conformance suite sends real documents (photos). It only runs when the dry-run copy is
# verifiably the process listening on the test port, so it can never reach a real printer.
set -uo pipefail
cd "${0:A:h}/.."
PORT="${PORT:-8640}"
TMP="$(mktemp -d)"
P=""
cleanup() { [[ -n "$P" ]] && kill "$P" 2>/dev/null; rm -rf "$TMP"; rm -rf "$HOME/Library/Caches/GD88Bridge/dry-run"; }
trap cleanup EXIT

echo "==> Building"
swiftc -O -o "$TMP/gd88bridge" src/*.swift -framework IOBluetooth -framework CoreBluetooth || exit 1
swiftc -Onone -o "$TMP/unit-tests" $(ls src/*.swift | grep -v '/main.swift$') tests/*.swift \
  -framework IOBluetooth -framework CoreBluetooth || exit 1

echo "==> Unit tests"
if ! "$TMP/unit-tests" 2> "$TMP/unit-tests.log"; then
  echo "--- bridge log output during the tests ---"; tail -20 "$TMP/unit-tests.log"; exit 1
fi

echo "==> Offline self-test"
/usr/bin/python3 -I tools/selftest.py "$TMP/gd88bridge" "$TMP" || exit 1

echo "==> IPP Everywhere conformance (dry run on port $PORT)"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ABORT: port $PORT is already in use"; exit 1
fi
"$TMP/gd88bridge" --dry-run --no-bonjour --ipp-port "$PORT" --raw-port 0 > "$TMP/bridge.log" 2>&1 &
P=$!
sleep 1
if ! lsof -nP -a -p "$P" -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || ! grep -q 'DRY RUN' "$TMP/bridge.log"; then
  echo "ABORT: the dry-run copy is not the one listening on port $PORT"; cat "$TMP/bridge.log"; exit 1
fi
( cd /usr/share/cups/ipptool && ipptool -t -f color.jpg "ipp://localhost:$PORT/ipp/print" ipp-everywhere.test ) > "$TMP/results.txt" 2>&1
grep -E '\[(PASS|FAIL)\]|^"' "$TMP/results.txt"
pass=$(grep -c '\[PASS\]' "$TMP/results.txt"); fail=$(grep -c '\[FAIL\]' "$TMP/results.txt"); skip=$(grep -c '\[SKIP\]' "$TMP/results.txt")
echo "PASS: $pass  FAIL: $fail  SKIP: $skip (skipped = features this printer doesn't have)"
if [[ "$fail" != "0" ]]; then
  awk '/\[FAIL\]/{p=1; print; next} /\[(PASS|SKIP)\]|^"/{p=0} p' "$TMP/results.txt" | head -40
  exit 1
fi
echo "==> All checks passed"
