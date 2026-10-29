#!/bin/bash
# test-poll.sh - Tests for how ../snaphatch-poll reads snaphatch-scan's output
#
# Sources snaphatch-poll (which then only defines its functions) and checks
# the parsing of `Done:` lines, the choice of error line and markup escaping.
# No scanner needed.
# Run: just test   (or: bash tests/test-poll.sh)

set -u

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../snaphatch-poll
source "$TEST_DIR/../snaphatch-poll"

PASS=0
FAIL=0

check() {
    local name=$1; shift
    if "$@"; then
        echo "  ok   $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL $name"
        FAIL=$((FAIL + 1))
    fi
}

# check_eq NAME EXPECTED ACTUAL
check_eq() {
    if [ "$2" = "$3" ]; then
        check "$1" true
    else
        check "$1" false
        echo "       expected: $2"
        echo "       got:      $3"
    fi
}

echo "Done line:"
check_eq "API mode file name" "scan-2026-10-29-132116.pdf" \
    "$(done_target "Done: scan-2026-10-29-132116.pdf (3 pages, 4.8M) uploaded to Paperless")"
check_eq "path with spaces" "/home/me/Documents/scanner-inbox/tax return 2025.pdf" \
    "$(done_target "Done: /home/me/Documents/scanner-inbox/tax return 2025.pdf (2 pages, 1.1M)")"
check_eq "only the Done line" "a b.pdf" \
    "$(done_target $'Scanned 2 page(s)\nDone: a b.pdf (2 pages, 900K)\nWaiting...')"

echo "Error line:"
check_eq "own message over server body" "Upload failed (HTTP 500)" \
    "$(error_message $'Uploading to Paperless...\nUpload failed (HTTP 500)\n<p>Server error</p>')"
check_eq "scanimage error via scan" "Error: scanimage exited with status 9" \
    "$(error_message $'scanimage: sane_start: Document feeder jammed\nError: scanimage exited with status 9')"
check_eq "falls back to any error line" "ocrmypdf: error: bad input" \
    "$(error_message $'Running OCR...\nocrmypdf: error: bad input')"
check_eq "generic when nothing matches" "Something went wrong during scanning" \
    "$(error_message 'Running OCR...')"

echo "Kept scan:"
check_eq "path from the error line" "/home/me/Documents/scanner-inbox/failed/my scan.pdf" \
    "$(kept_file $'Upload failed (HTTP 500)\nError: upload to Paperless failed (HTTP 500); scan kept as /home/me/Documents/scanner-inbox/failed/my scan.pdf')"
check_eq "nothing when not kept" "" \
    "$(kept_file $'Error: scanimage exited with status 9')"

echo "Markup:"
check_eq "escapes & < >" "Tom &amp; Jerry &lt;b&gt;.pdf" \
    "$(echo "Tom & Jerry <b>.pdf" | escape_markup)"

echo "No supported scanner:"
# Run the poll script with a scanimage that lists nothing and a sleep that
# returns at once; it should give up after its retries and exit 0, so systemd
# doesn't restart it forever
FAKE=$(mktemp -d)
cat > "$FAKE/scanimage" <<EOF
#!/bin/sh
echo "\$*" >> "$FAKE/scanimage-calls"
EOF
printf '#!/bin/sh\nexit 0\n' > "$FAKE/sleep"
chmod +x "$FAKE/scanimage" "$FAKE/sleep"
env -u SCANNER_DEVICE PATH="$FAKE:$PATH" bash "$TEST_DIR/../snaphatch-poll" > "$FAKE/out" 2>&1
STATUS=$?
check_eq "exits 0" 0 "$STATUS"
check_eq "retries detection 15 times" 15 "$(grep -c '^-L$' "$FAKE/scanimage-calls")"
check "says why it stops" grep -q "not polling" "$FAKE/out"
rm -rf "$FAKE"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
