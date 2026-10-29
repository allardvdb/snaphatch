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
cp "$WORK/page.tiff" "\$(printf "\$pat" 1)"
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
# Fake ocrmypdf: always fails (only the local-mode run uses it)
printf '#!/bin/sh\necho "ocrmypdf: error: fake failure" >&2\nexit 2\n' > "$WORK/bin/ocrmypdf"
chmod +x "$WORK/bin/scanimage" "$WORK/bin/curl" "$WORK/bin/notify-send" "$WORK/bin/ocrmypdf"

# run_scan RUN [VAR=value...] - run scan in API mode, with RUN as the scan's
# name (so its PDF is RUN.pdf); output in $WORK/RUN-out
run_scan() {
    local run=$1; shift
    env -u NOTIFY_ID RUN="$run" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
        SCANNER_DEVICE=fake PAPERLESS_URL=https://paperless.example \
        PAPERLESS_TOKEN=secret "$@" bash "$TEST_DIR/../scan" "$run" > "$WORK/$run-out" 2>&1
}
FAILED_DIR="$WORK/home/Documents/scanner-inbox/failed"
is_pdf() { [ "$(head -c 5 "$1" 2>/dev/null)" = "%PDF-" ]; }

# Standalone, as from a terminal: scan owns the notification
run_scan solo
STATUS=$?
# Started by scan-button-poll, which passes the ID of its popup
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
# scan-button-poll sends the final notification itself
check "from poll: no final notification"   bash -c "! grep -q 'Scan Complete' '$WORK/poll-notify'"
check "failed upload: exits 1"             [ "$FAIL_STATUS" -eq 1 ]
check "failed upload: says so"             grep -q '^Upload failed (HTTP 500)$' "$WORK/fail-out"
check "failed upload: keeps the PDF"       is_pdf "$FAILED_DIR/fail.pdf"
check "failed upload: says where"          grep -qx "Error: upload to Paperless failed (HTTP 500); scan kept as $FAILED_DIR/fail.pdf" "$WORK/fail-out"
check "failed upload: ends with Scan Failed" bash -c "tail -1 '$WORK/fail-notify' | grep -q '^-r|7|-u|critical|.*|Scan Failed|'"

echo "No pages:"
check "empty feeder: exits 1"           [ "$EMPTY_STATUS" -eq 1 ]
check "empty feeder: says so"           grep -qx 'No pages scanned (feeder empty?)' "$WORK/empty-out"
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
check "OCR failure: no partial output"  [ ! -e "$WORK/home/Documents/scanner-inbox/noocr.pdf" ]

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || for run in solo poll fail empty broken jam nofolder noocr; do
    echo "--- $run: scan output"; cat "$WORK/$run-out"
    echo "--- $run: notify-send calls"; cat "$WORK/$run-notify"
done
[ "$FAIL" -eq 0 ]
