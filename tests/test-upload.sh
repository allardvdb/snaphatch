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

# Fake scanimage: writes the page to the --batch pattern
cat > "$WORK/bin/scanimage" <<EOF
#!/bin/bash
for a in "\$@"; do case \$a in --batch=*) pat=\${a#--batch=};; esac; done
cp "$WORK/page.tiff" "\$(printf "\$pat" 1)"
EOF
# Fake curl: records its arguments, answers HTTP 200
cat > "$WORK/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/curl-args"
printf '"task-id"\n200'
EOF
chmod +x "$WORK/bin/scanimage" "$WORK/bin/curl"

HOME="$WORK/home" PATH="$WORK/bin:$PATH" SCANNER_DEVICE=fake \
    PAPERLESS_URL=https://paperless.example PAPERLESS_TOKEN=secret \
    bash "$TEST_DIR/../scan" > "$WORK/out" 2>&1
STATUS=$?

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
check "uploads the PDF"              grep -q '^document=@.*\.pdf$' "$WORK/curl-args"
# Paperless reads the document date from the document itself
check "sends no created date"        bash -c "! grep -q '^created=' '$WORK/curl-args'"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "--- scan output:"; cat "$WORK/out"; }
[ "$FAIL" -eq 0 ]
