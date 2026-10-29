#!/bin/bash
# test-upload.sh - Runs `scan` in Paperless API mode with a fake scanimage and a
# fake curl, and checks what is sent to Paperless. No scanner or network needed.
# Run: just test

set -u

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"

# One A4 page with "text lines"
LINES=""
for y in $(seq 400 120 3100); do
    LINES+="rectangle 300,$y 2180,$((y + 25)) "
done
magick -size 2480x3508 xc:white -fill black -draw "$LINES" "$WORK/page.tiff"
# And a blank one
magick -size 2480x3508 xc:white "$WORK/white.tiff"

# The fakes write what they were called with to $WORK/<run>-*, where RUN is
# set per run of scan below.
# Fake scanimage: answers the option probe (-A) with a few iX500 options, and
# otherwise records its arguments and writes the page to the --batch pattern
cat > "$WORK/bin/scanimage" <<EOF
#!/bin/bash
if [ "\$1" = "-A" ]; then
    printf '    --swcrop[=(yes|no)] [no]\\n    --overscan Auto|Off|On [Auto]\\n    --swskip 0..100%% [0]\\n'
    exit 0
fi
printf '%s\\n' "\$@" > "$WORK/\$RUN-scanimage-args"
# FAKE_SCAN_EXIT: fail like the real scanimage, without writing a page
if [ -n "\${FAKE_SCAN_EXIT:-}" ]; then
    echo "scanimage: sane_start: Document feeder out of documents" >&2
    exit "\$FAKE_SCAN_EXIT"
fi
for a in "\$@"; do case \$a in --batch=*) pat=\${a#--batch=};; esac; done
# FAKE_BLANK=1: scan a blank page
page="$WORK/page.tiff"
[ -n "\${FAKE_BLANK:-}" ] && page="$WORK/white.tiff"
cp "\$page" "\$(printf "\$pat" 1)"
# FAKE_SCAN_EXIT_AFTER: fail after the first page, like a jam on the 2nd sheet
[ -n "\${FAKE_SCAN_EXIT_AFTER:-}" ] && exit "\$FAKE_SCAN_EXIT_AFTER"
exit 0
EOF
# Fake curl: records its arguments, answers HTTP 200 (or FAKE_HTTP)
cat > "$WORK/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/\$RUN-curl-args"
printf '"task-id"\n%s' "\${FAKE_HTTP:-200}"
EOF
# Fake notify-send: logs each call as one |-separated line, answers
# --print-id with ID 7
cat > "$WORK/bin/notify-send" <<EOF
#!/bin/bash
(IFS='|'; echo "\$*") >> "$WORK/\$RUN-notify"
for a in "\$@"; do [ "\$a" = --print-id ] && echo 7; done
exit 0
EOF
# Fake systemctl: scan pauses the button service on a manual run, and this
# must never reach the real one. is-active answers from FAKE_SERVICE_ACTIVE
# (default: not running).
cat > "$WORK/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/\$RUN-systemctl"
[ "\$2" = is-active ] && exit "\${FAKE_SERVICE_ACTIVE:-3}"
exit 0
EOF
# Fake ocrmypdf: fails, unless FAKE_OCR_OK=1, then copies its input to its
# output (only the local-mode runs use it)
cat > "$WORK/bin/ocrmypdf" <<'EOF'
#!/bin/sh
[ -n "${FAKE_OCR_OK:-}" ] && exec cp "$1" "$2"
echo "ocrmypdf: error: fake failure" >&2
exit 2
EOF
# Fake xdg-user-dir: the documents folder is FAKE_DOCS
cat > "$WORK/bin/xdg-user-dir" <<EOF
#!/bin/sh
echo "\${FAKE_DOCS:-$WORK/home/Docs}"
EOF
chmod +x "$WORK/bin/scanimage" "$WORK/bin/curl" "$WORK/bin/notify-send" "$WORK/bin/ocrmypdf" "$WORK/bin/systemctl" "$WORK/bin/xdg-user-dir"
if [ "$(PATH="$WORK/bin:$PATH" command -v systemctl)" != "$WORK/bin/systemctl" ]; then
    echo "fake systemctl is not first on PATH, not running"; exit 1
fi

# run_scan RUN [VAR=value...] - run scan in API mode, with RUN as the scan's
# name (so its PDF is RUN.pdf); output in $WORK/RUN-out
# Settings from the developer's own session must not leak into the runs, so
# every config key is unset first. The config file is $WORK/RUN.conf, which
# only exists when a test writes it. NO_TOKEN=1 leaves PAPERLESS_TOKEN unset.
run_scan() {
    local run=$1; shift
    local token=(PAPERLESS_TOKEN=secret)
    [ "${NO_TOKEN:-}" = 1 ] && token=()
    env -u NOTIFY_ID -u SCANNER_DEVICE -u COLOR_DETECT -u PAPERLESS_URL -u PAPERLESS_TOKEN \
        -u PAPERLESS_CA -u PAPERLESS_CONSUME_DIR -u BLANK_THRESHOLD -u JPEG_QUALITY \
        RUN="$run" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
        SNAPHATCH_CONFIG="$WORK/$run.conf" XDG_CONFIG_HOME="$WORK/xdg-config" \
        XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
        SCANNER_DEVICE=fake PAPERLESS_URL=https://paperless.example \
        "${token[@]}" "$@" bash "$TEST_DIR/../snaphatch-scan" "$run" > "$WORK/$run-out" 2>&1
}
FAILED_DIR="$WORK/home/Docs/snaphatch/failed"
# wait_for FILE PATTERN - a notification with an action is sent in the
# background after scan exits; give it up to 2s to arrive
wait_for() {
    for _ in $(seq 20); do
        grep -q -- "$2" "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
is_pdf() { [ "$(head -c 5 "$1" 2>/dev/null)" = "%PDF-" ]; }

# Standalone, as from a terminal: scan owns the notification
run_scan solo
STATUS=$?
# Started by snaphatch-poll, which passes the ID of its popup
run_scan poll NOTIFY_ID=42
POLL_STATUS=$?
# Standalone with a failed upload
run_scan fail FAKE_HTTP=500
FAIL_STATUS=$?
# Button pressed with an empty feeder: scanimage exits 7 (SANE_STATUS_NO_DOCS)
run_scan empty FAKE_SCAN_EXIT=7
EMPTY_STATUS=$?
# Any other scanimage failure without pages
run_scan broken FAKE_SCAN_EXIT=9
BROKEN_STATUS=$?
# A jam after the first page
run_scan jam FAKE_SCAN_EXIT_AFTER=6
JAM_STATUS=$?
# Folder mode with a consume folder that doesn't exist
run_scan nofolder PAPERLESS_URL= PAPERLESS_TOKEN= PAPERLESS_CONSUME_DIR="$WORK/missing/consume"
NOFOLDER_STATUS=$?
# Local mode with a failing ocrmypdf
run_scan noocr PAPERLESS_URL= PAPERLESS_TOKEN=
NOOCR_STATUS=$?
# Manual run while the button service is running
run_scan paused FAKE_SERVICE_ACTIVE=0
PAUSED_STATUS=$?
# Run by the button service while it is running: must not stop itself
run_scan pollactive NOTIFY_ID=42 FAKE_SERVICE_ACTIVE=0
# The config file: a value only in the file
printf '%s\n' 'PAPERLESS_CA="/etc/my ca.pem"' > "$WORK/cfgca.conf"
run_scan cfgca
# The same key in the file and the environment
printf '%s\n' 'PAPERLESS_URL=https://from-file.example' > "$WORK/cfgenv.conf"
run_scan cfgenv PAPERLESS_URL=https://from-env.example
# Values with = and spaces, among lines that must be skipped
printf '%s\n' '# comment' 'PAPERLESS_TOKEN=abc=def==' "PAPERLESS_CA='/etc/a b.pem'" \
    'NOT_OURS=1' 'garbage line' '' > "$WORK/cfgeq.conf"
NO_TOKEN=1 run_scan cfgeq
# Paths: a scan whose only page is blank
run_scan blank FAKE_BLANK=1
# Local mode with a working ocrmypdf
run_scan localok PAPERLESS_URL= PAPERLESS_TOKEN= FAKE_OCR_OK=1
# xdg-user-dir answers $HOME when no documents folder is configured
run_scan homedocs FAKE_DOCS="$WORK/home" FAKE_HTTP=500
# A page setting from the file: with a 100% threshold every page is blank
printf '%s\n' 'BLANK_THRESHOLD=100' > "$WORK/cfgblank.conf"
run_scan cfgblank

PASS=0
FAIL=0
check() {
    local name=$1; shift
    if "$@"; then
        echo "  ok   $name"; PASS=$((PASS + 1))
    else
        echo "  FAIL $name"; FAIL=$((FAIL + 1))
    fi
}

echo "Paperless API upload:"
check "scan exits 0"                 [ "$STATUS" -eq 0 ]
check "uploads the PDF"              grep -q '^document=@.*\.pdf$' "$WORK/solo-curl-args"
# Paperless reads the document date from the document itself
check "sends no created date"        bash -c "! grep -q '^created=' '$WORK/solo-curl-args'"
check "has a connect timeout"        grep -qx -- '--connect-timeout' "$WORK/solo-curl-args"
check "has a maximum time"           grep -qx -- '--max-time' "$WORK/solo-curl-args"
check "keeps nothing when it works"  [ ! -e "$FAILED_DIR/solo.pdf" ]

echo "Scanner options:"
check "passes probed options"        grep -q '^--swcrop=yes$' "$WORK/solo-scanimage-args"
check "skips unsupported options"    bash -c "! grep -q '^--prepick$' '$WORK/solo-scanimage-args'"
# Blank pages are removed by is_blank, not by the scanner
check "never passes --swskip"        bash -c "! grep -q '^--swskip$' '$WORK/solo-scanimage-args'"

echo "Notifications:"
check "standalone: first call gets an ID"  bash -c "head -1 '$WORK/solo-notify' | grep -q -- '--print-id|-t|0|'"
check "standalone: ends with Scan Complete" bash -c "tail -1 '$WORK/solo-notify' | grep -q '^-r|7|.*|Scan Complete|'"
# A final notification with -t 0 would never expire
check "standalone: final one expires"      bash -c "! tail -1 '$WORK/solo-notify' | grep -q -- '-t|0'"
# GNOME never banners low urgency and keeps it for the replacing notification
check "never low urgency"                  bash -c "! cat '$WORK'/*-notify | grep -q -- '-u|low'"
check "from poll: exits 0"                 [ "$POLL_STATUS" -eq 0 ]
check "from poll: only updates its popup"  bash -c "! grep -v '^-r|42|' '$WORK/poll-notify'"
# snaphatch-poll sends the final notification itself
check "from poll: no final notification"   bash -c "! grep -q 'Scan Complete' '$WORK/poll-notify'"
check "failed upload: exits 1"             [ "$FAIL_STATUS" -eq 1 ]
check "failed upload: says so"             grep -q '^Upload failed (HTTP 500)$' "$WORK/fail-out"
check "failed upload: keeps the PDF"       is_pdf "$FAILED_DIR/fail.pdf"
check "failed upload: says where"          grep -qx "Error: upload to Paperless failed (HTTP 500); scan kept as $FAILED_DIR/fail.pdf" "$WORK/fail-out"
wait_for "$WORK/fail-notify" "Scan Failed"
check "failed upload: ends with Scan Failed" bash -c "tail -1 '$WORK/fail-notify' | grep -q '^-r|7|-u|critical|.*|Scan Failed|'"
check "failed upload: shows the error"     bash -c "tail -1 '$WORK/fail-notify' | grep -qF '|Scan Failed|Error: upload to Paperless failed (HTTP 500); scan kept as $FAILED_DIR/fail.pdf'"
check "failed upload: offers Open folder"  bash -c "tail -1 '$WORK/fail-notify' | grep -qF -- '--action=folder=Open folder'"

echo "No pages:"
check "empty feeder: exits 1"           [ "$EMPTY_STATUS" -eq 1 ]
check "empty feeder: says so"           grep -qx 'No pages scanned (feeder empty?)' "$WORK/empty-out"
check "empty feeder: notification too"  bash -c "tail -1 '$WORK/empty-notify' | grep -qF '|Scan Failed|No pages scanned (feeder empty?)'"
# Nothing was kept, so no folder to open
check "empty feeder: no Open folder"    bash -c "! tail -1 '$WORK/empty-notify' | grep -q -- '--action'"
check "scanner error: exits 1"          [ "$BROKEN_STATUS" -eq 1 ]
check "scanner error: reports status"   grep -qx 'Error: scanimage exited with status 9' "$WORK/broken-out"

echo "Never lose a scan:"
check "jam: exits 1"                    [ "$JAM_STATUS" -eq 1 ]
check "jam: delivers nothing"           [ ! -e "$WORK/jam-curl-args" ]
check "jam: keeps the pages"            is_pdf "$FAILED_DIR/jam.pdf"
check "jam: says why and where"         grep -qx "Error: scanimage exited with status 6 after 1 page(s), nothing delivered; scan kept as $FAILED_DIR/jam.pdf" "$WORK/jam-out"
check "no consume folder: exits 1"      [ "$NOFOLDER_STATUS" -eq 1 ]
check "no consume folder: keeps it"     is_pdf "$FAILED_DIR/nofolder.pdf"
check "OCR failure: exits 1"            [ "$NOOCR_STATUS" -eq 1 ]
check "OCR failure: keeps it"           is_pdf "$FAILED_DIR/noocr.pdf"
check "OCR failure: no partial output"  [ ! -e "$WORK/home/Docs/snaphatch/noocr.pdf" ]

echo "Config file:"
check "config: value from file reaches curl"  bash -c "grep -qx -- '--cacert' '$WORK/cfgca-curl-args' && grep -qx '/etc/my ca.pem' '$WORK/cfgca-curl-args'"
check "config: environment wins"              [ "$(tail -1 "$WORK/cfgenv-curl-args")" = "https://from-env.example/api/documents/post_document/" ]
check "config: page settings from file"      grep -qx 'Error: all pages were blank, nothing to save' "$WORK/cfgblank-out"
check "config: keeps spaces and = in values"  bash -c "grep -qx 'Authorization: Token abc=def==' '$WORK/cfgeq-curl-args' && grep -qx '/etc/a b.pem' '$WORK/cfgeq-curl-args'"

echo "Paths:"
check "paths: removed pages in state"        bash -c "ls '$WORK/state/snaphatch/removed/'blank-*.jpg >/dev/null"
check "paths: working dir in cache and removed" bash -c "[ -d '$WORK/cache/snaphatch' ] && [ -z \"\$(ls -A '$WORK/cache/snaphatch')\" ]"
check "paths: local output in documents"     [ -f "$WORK/home/Docs/snaphatch/localok.pdf" ]
check "paths: home as documents falls back"  [ -f "$WORK/home/Documents/snaphatch/failed/homedocs.pdf" ]

echo "Button service during a manual scan:"
check "paused: exits 0"                 [ "$PAUSED_STATUS" -eq 0 ]
check "paused: stops the service"       grep -qx -- '--user stop snaphatch.service' "$WORK/paused-systemctl"
check "paused: starts it again"         grep -qx -- '--user start --no-block snaphatch.service' "$WORK/paused-systemctl"
check "paused: says so"                 grep -q '^Pausing the scan button service' "$WORK/paused-out"
check "not running: left alone"         bash -c "! grep -qE -- '--user (stop|start)' '$WORK/solo-systemctl'"
# Stopping the service would kill the scan it is running
check "run by the service: left alone"  bash -c "! grep -qE -- '--user (stop|start)' '$WORK/pollactive-systemctl' 2>/dev/null"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || for run in solo poll fail empty broken jam nofolder noocr paused pollactive cfgca cfgenv cfgeq cfgblank blank localok homedocs; do
    echo "--- $run: scan output"; cat "$WORK/$run-out"
    echo "--- $run: notify-send calls"; cat "$WORK/$run-notify"
done
[ "$FAIL" -eq 0 ]
