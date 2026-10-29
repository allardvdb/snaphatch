#!/bin/bash
# test-cli.sh - Tests for the snaphatch command (../snaphatch)
#
# Copies the dispatcher into a temporary lib folder next to a stub
# snaphatch-scan, calls it directly and through a symlink, and fakes
# systemctl and journalctl. No scanner or service needed.
# Run: just test   (or: bash tests/test-cli.sh)

set -u

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib" "$WORK/bin" "$WORK/fake"

cp "$TEST_DIR/../snaphatch" "$WORK/lib/snaphatch"
chmod +x "$WORK/lib/snaphatch"
printf '#!/bin/sh\necho "scan-args:$*"\n' > "$WORK/lib/snaphatch-scan"
chmod +x "$WORK/lib/snaphatch-scan"
ln -s "$WORK/lib/snaphatch" "$WORK/bin/snaphatch"

# Fakes log their arguments; is-active answers from FAKE_DEVICE_ACTIVE
for cmd in systemctl journalctl; do
    cat > "$WORK/fake/$cmd" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/$cmd.log"
[ "\$2" = is-active ] && exit "\${FAKE_DEVICE_ACTIVE:-0}"
exit 0
EOF
    chmod +x "$WORK/fake/$cmd"
done
if [ "$(PATH="$WORK/fake:$PATH" command -v systemctl)" != "$WORK/fake/systemctl" ]; then
    echo "fake systemctl is not first on PATH, not running"; exit 1
fi

# run NAME ARGS... - run the dispatcher from lib; stdout, stderr and status
# in $WORK/NAME.{out,err,status}
run() {
    local name=$1; shift
    PATH="$WORK/fake:$PATH" "$WORK/lib/snaphatch" "$@" > "$WORK/$name.out" 2> "$WORK/$name.err"
    echo $? > "$WORK/$name.status"
}

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

run noarg
run unknown frobnicate
run help --help
run scan scan "my doc"
PATH="$WORK/fake:$PATH" "$WORK/bin/snaphatch" scan "my doc" > "$WORK/symlink.out" 2>&1
FAKE_DEVICE_ACTIVE=3 run unplugged restart
run status status

echo "Usage:"
check "no argument: usage, exit 2"       bash -c "grep -q '^Usage: snaphatch' '$WORK/noarg.err' && [ \$(cat '$WORK/noarg.status') -eq 2 ]"
check "unknown command: exit 2"          [ "$(cat "$WORK/unknown.status")" -eq 2 ]
check "--help: exit 0"                   bash -c "grep -q '^Usage: snaphatch' '$WORK/help.out' && [ \$(cat '$WORK/help.status') -eq 0 ]"

echo "Commands:"
check "scan passes the name"             [ "$(cat "$WORK/scan.out")" = "scan-args:my doc" ]
check "works through the symlink"        [ "$(cat "$WORK/symlink.out")" = "scan-args:my doc" ]
check "restart without scanner: no restart" bash -c "! grep -q restart '$WORK/systemctl.log' && grep -q 'starts when you connect' '$WORK/unplugged.out'"
check "status: calls systemctl"          grep -qx -- '--user status snaphatch.service' "$WORK/systemctl.log"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
