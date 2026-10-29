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
for a in "\$@"; do case \$a in --batch=*) pat=\${a#--batch=};; esac; done
cp "$WORK/page.tiff" "\$(printf "\$pat" 1)"
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
chmod +x "$WORK/bin/scanimage" "$WORK/bin/curl" "$WORK/bin/notify-send"

# run_scan RUN [VAR=value...] - run scan in API mode; output in $WORK/RUN-out
run_scan() {
    local run=$1; shift
    env -u NOTIFY_ID RUN="$run" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
        SCANNER_DEVICE=fake PAPERLESS_URL=https://paperless.example \
        PAPERLESS_TOKEN=secret "$@" bash "$TEST_DIR/../scan" > "$WORK/$run-out" 2>&1
}

# Standalone, as from a terminal: scan owns the notification
run_scan solo
STATUS=$?
# Started by scan-button-poll, which passes the ID of its popup
run_scan poll NOTIFY_ID=42
POLL_STATUS=$?
# Standalone with a failed upload
run_scan fail FAKE_HTTP=500
FAIL_STATUS=$?

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
check "failed upload: ends with Scan Failed" bash -c "tail -1 '$WORK/fail-notify' | grep -q '^-r|7|-u|critical|.*|Scan Failed|'"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || for run in solo poll fail; do
    echo "--- $run: scan output"; cat "$WORK/$run-out"
    echo "--- $run: notify-send calls"; cat "$WORK/$run-notify"
done
[ "$FAIL" -eq 0 ]
