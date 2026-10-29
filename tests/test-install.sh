#!/bin/bash
# test-install.sh - Runs `just install` with scripted answers against a
# temporary HOME, with fake systemctl, sudo, udevadm, scanimage, lsusb and curl
# first on PATH. Checks the written config, what is pushed to the service,
# and that the service is restarted. Nothing on the real system is touched.
# Run: just test   (or: bash tests/test-install.sh)

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fakes log their arguments to $WORK/$RUN-<name>; RUN is set per scenario
for cmd in systemctl udevadm; do
    cat > "$WORK/bin/$cmd" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/\$RUN-$cmd"
# is-active answers from FAKE_ACTIVE (0 = running)
[ "\$1 \$2" = "--user is-active" ] && exit "\${FAKE_ACTIVE:-0}"
exit 0
EOF
done
cat > "$WORK/bin/sudo" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/\$RUN-sudo"
# The rules file is written with \`sudo tee\`; keep it out of /etc
[ "\$1" = tee ] && cat > "$WORK/\$RUN-rules"
exit 0
EOF
# scanimage -L lists the devices in FAKE_DEVICES (one per line)
cat > "$WORK/bin/scanimage" <<EOF
#!/bin/bash
[ "\$1" = -L ] && [ -n "\${FAKE_DEVICES:-}" ] && printf "device \\\`%s' is a FUJITSU ScanSnap scanner\\n" "\$FAKE_DEVICES"
exit 0
EOF
printf '#!/bin/sh\necho 200\n' > "$WORK/bin/curl"
for cmd in lsusb notify-send xdg-open xdg-terminal-exec; do
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$cmd"
done
chmod +x "$WORK/bin/"*

# Never run against the real system
for cmd in systemctl sudo udevadm scanimage; do
    if [ "$(PATH="$WORK/bin:$PATH" command -v "$cmd")" != "$WORK/bin/$cmd" ]; then
        echo "fake $cmd is not first on PATH, not running"; exit 1
    fi
done

# install RUN CONFIG ANSWERS [VAR=value...] - run `just install` with CONFIG as
# the existing scanner.conf (empty: none) and ANSWERS on stdin
install() {
    local run=$1 config=$2 answers=$3; shift 3
    mkdir -p "$WORK/$run/.config/environment.d"
    [ -n "$config" ] && printf '%s\n' "$config" > "$WORK/$run/.config/environment.d/scanner.conf"
    printf '%s' "$answers" | env RUN="$run" HOME="$WORK/$run" PATH="$WORK/bin:$PATH" "$@" \
        just --justfile "$ROOT/justfile" install > "$WORK/$run-out" 2>&1
}
conf() { echo "$WORK/$1/.config/environment.d/scanner.conf"; }

PASS=0
FAIL=0
check() {
    local name=$1; shift
    if "$@"; then
        echo "  ok   $name"; PASS=$((PASS + 1))
    else
        echo "  FAIL $name"; FAIL=$((FAIL + 1)); FAILED_RUNS+=" $RUN_NAME"
    fi
}
FAILED_RUNS=""

API_CONFIG='# Scanner configuration for ix500-linux
SCANNER_DEVICE="fujitsu:ScanSnap iX500:1"
COLOR_DETECT=true
PAPERLESS_URL=https://paperless.example
PAPERLESS_TOKEN=secret1234
PAPERLESS_CA=/etc/ca.pem
# my own note
BLANK_THRESHOLD=0.05'

echo "Keep current values, scanner still there:"
RUN_NAME=keep
install keep "$API_CONFIG" $'\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1"
STATUS=$?
check "exits 0"                          [ "$STATUS" -eq 0 ]
check "keeps hand-added settings"        grep -qx 'BLANK_THRESHOLD=0.05' "$(conf keep)"
check "keeps comments"                   grep -qx '# my own note' "$(conf keep)"
check "keeps PAPERLESS_CA"               grep -qx 'PAPERLESS_CA=/etc/ca.pem' "$(conf keep)"
check "device without the quotes"        grep -qx 'SCANNER_DEVICE=fujitsu:ScanSnap iX500:1' "$(conf keep)"
check "writes the header once"           [ "$(grep -c '^# Scanner configuration' "$(conf keep)")" -eq 1 ]
check "pushes hand-added settings"       grep -q 'set-environment .*BLANK_THRESHOLD=0.05' "$WORK/keep-systemctl"
check "restarts the service"             grep -qx -- '--user restart scan-button.service' "$WORK/keep-systemctl"

echo "Keep current values, saved scanner gone, two others connected:"
RUN_NAME=gone
install gone "$API_CONFIG" $'\nx\n9\n2\n' FAKE_DEVICES=$'fujitsu:ScanSnap iX500:2\nfujitsu:ScanSnap S1500:3'
STATUS=$?
check "exits 0"                          [ "$STATUS" -eq 0 ]
check "says the saved one is gone"       grep -q 'Saved scanner (fujitsu:ScanSnap iX500:1) not detected' "$WORK/gone-out"
check "asks again on bad input"          [ "$(grep -c 'Enter a number from 1 to 2' "$WORK/gone-out")" -eq 2 ]
check "uses the chosen device"           grep -qx 'SCANNER_DEVICE=fujitsu:ScanSnap S1500:3' "$(conf gone)"

echo "Reconfigure with two scanners, saved one connected:"
RUN_NAME=reconf
SAVED_S1500="${API_CONFIG/iX500:1/S1500:3}"
# reconfigure, mode (API), device (default), color, URL, token, CA
install reconf "$SAVED_S1500" $'n\n\n\n\n\n\n\n' FAKE_DEVICES=$'fujitsu:ScanSnap iX500:2\nfujitsu:ScanSnap S1500:3'
STATUS=$?
check "exits 0"                          [ "$STATUS" -eq 0 ]
check "shows the picker"                 grep -q '2) fujitsu:ScanSnap S1500:3 (current)' "$WORK/reconf-out"
check "defaults to the current device"   grep -qx 'SCANNER_DEVICE=fujitsu:ScanSnap S1500:3' "$(conf reconf)"

echo "Install stops early, service was running:"
RUN_NAME=abort
# reconfigure, folder mode, device (yes), color, no consume folder -> error
install abort "$API_CONFIG" $'n\n2\n\n\n\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1" FAKE_ACTIVE=0
STATUS=$?
check "exits non-zero"                   [ "$STATUS" -ne 0 ]
check "stopped the service"              grep -qx -- '--user stop scan-button.service' "$WORK/abort-systemctl"
check "starts it again"                  grep -qx -- '--user start scan-button.service' "$WORK/abort-systemctl"

echo "Install stops early, service was not running:"
RUN_NAME=abort-idle
install abort-idle "$API_CONFIG" $'n\n2\n\n\n\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1" FAKE_ACTIVE=3
check "does not start it"                bash -c "! grep -q -- '--user start' '$WORK/abort-idle-systemctl'"

echo
echo "$PASS passed, $FAIL failed"
for run in $(echo "$FAILED_RUNS" | tr ' ' '\n' | sort -u); do
    echo "--- $run: installer output"; cat "$WORK/$run-out"
    [ -f "$WORK/$run/.config/environment.d/scanner.conf" ] && { echo "--- $run: scanner.conf"; cat "$(conf "$run")"; }
done
[ "$FAIL" -eq 0 ]
