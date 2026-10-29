#!/bin/bash
# test-install.sh - Runs `just install` with scripted answers against a
# temporary HOME, with fake systemctl, sudo, udevadm, scanimage, lsusb and curl
# first on PATH. Checks the written config, what is pushed to the service,
# and that the service is restarted. Nothing on the real system is touched.
# Run: just test   (or: bash tests/test-install.sh)

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fakes log their arguments to $WORK/$RUN-<name>; RUN is set per scenario
for cmd in systemctl udevadm; do
    cat > "$WORK/bin/$cmd" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/\$RUN-$cmd"
# is-active answers from FAKE_DEVICE_ACTIVE for the scanner's device unit
# and FAKE_ACTIVE for the service (0 = active)
if [ "\$1 \$2" = "--user is-active" ]; then
    [ "\$4" = dev-scansnap.device ] && exit "\${FAKE_DEVICE_ACTIVE:-0}"
    exit "\${FAKE_ACTIVE:-0}"
fi
exit 0
EOF
done
cat > "$WORK/bin/sudo" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/\$RUN-sudo"
# The rules file is written with \`sudo tee\`; keep it out of /etc
[ "\$1" = tee ] && cat > "$WORK/\$RUN-rules"
# rm really removes: every rules path points into \$WORK (SNAPHATCH_UDEV_DIR)
if [ "\$1" = rm ]; then
    for f in "\$@"; do
        case "\$f" in rm|-f) ;; "$WORK"/*) ;; *) echo "fake sudo: refusing rm \$f" >&2; exit 1 ;; esac
    done
    exec "\$@"
fi
exit 0
EOF
# scanimage -L lists the devices in FAKE_DEVICES (one per line)
cat > "$WORK/bin/scanimage" <<EOF
#!/bin/bash
[ "\$1" = -L ] && [ -n "\${FAKE_DEVICES:-}" ] && printf "device \\\`%s' is a FUJITSU ScanSnap scanner\\n" "\$FAKE_DEVICES"
exit 0
EOF
printf '#!/bin/sh\necho 200\n' > "$WORK/bin/curl"
# Documents folder of the test HOME
printf '#!/bin/sh\necho "$HOME/Documents"\n' > "$WORK/bin/xdg-user-dir"
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
    mkdir -p "$WORK/$run/.config/snaphatch" "$WORK/$run/udev"
    [ -n "$config" ] && printf '%s\n' "$config" > "$WORK/$run/.config/snaphatch/snaphatch.conf"
    printf '%s' "$answers" | env RUN="$run" HOME="$WORK/$run" PATH="$WORK/bin:$PATH" \
        SNAPHATCH_UDEV_DIR="$WORK/$run/udev" "$@" \
        just --justfile "$ROOT/justfile" install > "$WORK/$run-out" 2>&1
}
conf() { echo "$WORK/$1/.config/snaphatch/snaphatch.conf"; }

# old_install RUN - an ix500-linux install as it was before the rename
old_install() {
    local h="$WORK/$1"
    mkdir -p "$h/.config/environment.d" "$h/.config/systemd/user" "$h/.local/bin" "$h/udev" \
        "$h/Documents/scanner-inbox/failed" "$h/Documents/scanner-inbox/removed"
    printf '%s\n' "$API_CONFIG" > "$h/.config/environment.d/scanner.conf"
    echo '[Unit]' > "$h/.config/systemd/user/scan-button.service"
    printf '#!/bin/bash\n# scan - Quick scan from a Fujitsu ScanSnap\n' > "$h/.local/bin/scan"
    printf '#!/bin/bash\n# scan-button-poll - Poll ScanSnap button and trigger scan\n' > "$h/.local/bin/scan-button-poll"
    touch "$h/udev/99-scansnap.rules" "$h/udev/99-scansnap-ix500.rules"
    echo old > "$h/Documents/scanner-inbox/failed/old-fail.pdf"
    echo old > "$h/Documents/scanner-inbox/removed/old-blank.jpg"
    echo old > "$h/Documents/scanner-inbox/old-local.pdf"
}

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
check "writes the header once"           [ "$(grep -cE '^# (Scanner|snaphatch) configuration' "$(conf keep)")" -eq 1 ]
check "config is private"                [ "$(stat -c %a "$(conf keep)")" = 600 ]
check "unit reads the config"            grep -qx 'EnvironmentFile=-%h/.config/snaphatch/snaphatch.conf' "$WORK/keep/.config/systemd/user/snaphatch.service"
# systemd reads the file on every start; nothing is pushed into the session
check "pushes nothing to the session"    bash -c "! grep -q set-environment '$WORK/keep-systemctl'"
check "restarts the service"             grep -qx -- '--user restart snaphatch.service' "$WORK/keep-systemctl"
check "installs the udev rule as is"     grep -qx "install -m 0644 $ROOT/99-snaphatch.rules $WORK/keep/udev/99-snaphatch.rules" "$WORK/keep-sudo"
check "installs the scripts in lib"      [ -x "$WORK/keep/.local/lib/snaphatch/snaphatch-scan" ] && [ -x "$WORK/keep/.local/lib/snaphatch/snaphatch-poll" ]
check "fresh: symlink resolves"          [ "$(readlink -f "$WORK/keep/.local/bin/snaphatch")" = "$WORK/keep/.local/lib/snaphatch/snaphatch" ]
# The keep run's PATH doesn't contain its HOME's ~/.local/bin
check "fresh: warns when ~/.local/bin is not on PATH" grep -q 'is not on your PATH' "$WORK/keep-out"
check "unit runs the poll from lib"      grep -qx 'ExecStart=%h/.local/lib/snaphatch/snaphatch-poll' "$WORK/keep/.config/systemd/user/snaphatch.service"
check "waits for udev before restarting" grep -qx 'udevadm settle' "$WORK/keep-sudo"
check "installs the bound unit"          grep -qx 'BindsTo=dev-scansnap.device' "$WORK/keep/.config/systemd/user/snaphatch.service"
# Unplugging stops the service with SIGTERM; that must not count as failed
check "SIGTERM exit is success"          grep -qx 'SuccessExitStatus=143' "$WORK/keep/.config/systemd/user/snaphatch.service"

echo "Keep current values, ~/.local/bin on PATH:"
RUN_NAME=onpath
install onpath "$API_CONFIG" $'\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1" PATH="$WORK/bin:$WORK/onpath/.local/bin:$PATH"
check "no PATH warning"                  bash -c "! grep -q 'is not on your PATH' '$WORK/onpath-out'"

echo "Keep current values, no scanner connected:"
RUN_NAME=unplugged
install unplugged "$API_CONFIG" $'\n' FAKE_DEVICE_ACTIVE=3
STATUS=$?
check "exits 0"                          [ "$STATUS" -eq 0 ]
check "keeps the saved device"           grep -qx 'SCANNER_DEVICE=fujitsu:ScanSnap iX500:1' "$(conf unplugged)"
# A restart would wait for the scanner (BindsTo)
check "does not restart the service"     bash -c "! grep -q -- '--user restart' '$WORK/unplugged-systemctl'"
check "says it starts on connect"        grep -q 'the service starts when you connect it' "$WORK/unplugged-out"

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
check "stopped the service"              grep -qx -- '--user stop snaphatch.service' "$WORK/abort-systemctl"
check "starts it again"                  grep -qx -- '--user start --no-block snaphatch.service' "$WORK/abort-systemctl"

echo "Install stops early, service was not running:"
RUN_NAME=abort-idle
install abort-idle "$API_CONFIG" $'n\n2\n\n\n\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1" FAKE_ACTIVE=3
check "does not start it"                bash -c "! grep -q -- '--user start' '$WORK/abort-idle-systemctl'"

echo "Migration from ix500-linux:"
RUN_NAME=migrate
old_install migrate
install migrate "" $'\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1"
H="$WORK/migrate"
check "migration: exits 0"                    [ "$(grep -c 'Installation complete' "$WORK/migrate-out")" -eq 1 ]
check "migration: values moved"               bash -c "grep -qx 'PAPERLESS_CA=/etc/ca.pem' '$(conf migrate)' && grep -qx 'BLANK_THRESHOLD=0.05' '$(conf migrate)' && [ \$(stat -c %a '$(conf migrate)') = 600 ]"
check "migration: old config removed"         [ ! -e "$H/.config/environment.d/scanner.conf" ]
check "migration: session variables cleared"  bash -c "grep -- '^--user unset-environment' '$WORK/migrate-systemctl' | grep -q PAPERLESS_TOKEN && grep -- '^--user unset-environment' '$WORK/migrate-systemctl' | grep -q BLANK_THRESHOLD"
check "migration: old unit removed"           bash -c "[ ! -e '$H/.config/systemd/user/scan-button.service' ] && grep -qx -- '--user disable scan-button.service' '$WORK/migrate-systemctl'"
check "migration: old scripts removed"        bash -c "[ ! -e '$H/.local/bin/scan' ] && [ ! -e '$H/.local/bin/scan-button-poll' ]"
check "migration: old rules removed"          grep -qx "rm -f $H/udev/99-scansnap.rules $H/udev/99-scansnap-ix500.rules" "$WORK/migrate-sudo"
check "migration: failed scans moved"         bash -c "[ -f '$H/Documents/snaphatch/failed/old-fail.pdf' ] && [ ! -e '$H/Documents/scanner-inbox/failed/old-fail.pdf' ]"
check "migration: removed pages moved"        [ -f "$H/.local/state/snaphatch/removed/old-blank.jpg" ]
check "migration: local scans left in place"  [ -f "$H/Documents/scanner-inbox/old-local.pdf" ]
check "migration: summary"                    grep -q 'Migrated from ix500-linux' "$WORK/migrate-out"
cp "$(conf migrate)" "$WORK/migrate-first.conf"

RUN_NAME=migrate-again
RUN=migrate-again
printf '\n' | env RUN=migrate-again HOME="$H" PATH="$WORK/bin:$PATH" SNAPHATCH_UDEV_DIR="$H/udev" \
    FAKE_DEVICES="fujitsu:ScanSnap iX500:1" just --justfile "$ROOT/justfile" install > "$WORK/migrate-again-out" 2>&1
check "second run: nothing old found"         bash -c "! grep -q 'Migrated from' '$WORK/migrate-again-out' && cmp -s '$WORK/migrate-first.conf' '$(conf migrate)'"

RUN_NAME=foreign
old_install foreign
printf '#!/bin/sh\necho other\n' > "$WORK/foreign/.local/bin/scan"
install foreign "" $'\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1"
check "migration: foreign scan left alone"    grep -qx 'echo other' "$WORK/foreign/.local/bin/scan"

RUN_NAME=both-configs
old_install both-configs
install both-configs "${API_CONFIG/https:\/\/paperless.example/https://new.example}" $'\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1"
check "migration: new config wins over old"   bash -c "grep -qx 'PAPERLESS_URL=https://new.example' '$(conf both-configs)' && [ ! -e '$WORK/both-configs/.config/environment.d/scanner.conf' ]"

RUN_NAME=clash
old_install clash
mkdir -p "$WORK/clash/Documents/snaphatch/failed"
echo new > "$WORK/clash/Documents/snaphatch/failed/old-fail.pdf"
install clash "" $'\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1"
check "migration: name clash is skipped and kept" bash -c "[ \"\$(cat '$WORK/clash/Documents/snaphatch/failed/old-fail.pdf')\" = new ] && [ -f '$WORK/clash/Documents/scanner-inbox/failed/old-fail.pdf' ] && grep -q 'old-fail.pdf' '$WORK/clash-out' && grep -qi 'skipped' '$WORK/clash-out'"

RUN_NAME=migrate-abort
old_install migrate-abort
# reconfigure, folder mode, device (yes), color, no consume folder -> error
install migrate-abort "" $'n\n2\n\n\n\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1" FAKE_ACTIVE=0
H="$WORK/migrate-abort"
check "abort: old install intact"             bash -c "[ -f '$H/.config/environment.d/scanner.conf' ] && [ -f '$H/.config/systemd/user/scan-button.service' ] && [ -f '$H/.local/bin/scan' ] && grep -qx -- '--user start --no-block scan-button.service' '$WORK/migrate-abort-systemctl' && ! grep -q '^rm' '$WORK/migrate-abort-sudo' 2>/dev/null"

echo "Uninstall:"
RUN_NAME=uninstall
install uninstall "$API_CONFIG" $'\n' FAKE_DEVICES="fujitsu:ScanSnap iX500:1"
printf 'n\n' | env RUN=uninstall HOME="$WORK/uninstall" PATH="$WORK/bin:$PATH" SNAPHATCH_UDEV_DIR="$WORK/uninstall/udev" \
    just --justfile "$ROOT/justfile" uninstall > "$WORK/uninstall-out" 2>&1
check "uninstall: keeps config when declined" bash -c "[ -f '$(conf uninstall)' ] && [ ! -e '$WORK/uninstall/.local/lib/snaphatch' ] && [ ! -L '$WORK/uninstall/.local/bin/snaphatch' ]"

echo
echo "$PASS passed, $FAIL failed"
for run in $(echo "$FAILED_RUNS" | tr ' ' '\n' | sort -u); do
    echo "--- $run: installer output"; cat "$WORK/$run-out"
    [ -f "$(conf "$run")" ] && { echo "--- $run: scanner.conf"; cat "$(conf "$run")"; }
done
[ "$FAIL" -eq 0 ]
