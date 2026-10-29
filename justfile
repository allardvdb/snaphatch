# snaphatch — one-button scanning for Fujitsu ScanSnap scanners

# List available recipes
default:
    @just --list

# Full interactive install (mode selection, scanner detection, config, activate)
install:
    #!/usr/bin/env bash
    set -e

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'

    ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
    warn() { echo -e "  ${YELLOW}!${NC} $1"; }
    fail() { echo -e "  ${RED}✗${NC} $1"; }

    MISSING_SYSTEM=()

    check_cmd() {
        local cmd=$1 system_pkg=$2
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found: $(command -v "$cmd")"
            return 0
        else
            fail "$cmd not found"
            [ -n "$system_pkg" ] && MISSING_SYSTEM+=("$system_pkg")
            return 1
        fi
    }

    echo "snaphatch installer"
    echo "==================="
    echo

    # --- Load existing settings (if any) for use as defaults ---
    # Read by snaphatch.service (EnvironmentFile=) and by the scripts
    ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/snaphatch"
    ENV_FILE="$ENV_DIR/snaphatch.conf"
    OLD_ENV_FILE="$HOME/.config/environment.d/paperless.conf"

    # read_var VAR FILE - the value of VAR=... in FILE, without surrounding quotes
    read_var() {
        local var=$1 file=$2 val
        val=$([ -f "$file" ] && grep -oP "(?<=^${var}=).+" "$file" 2>/dev/null | tail -1 || true)
        case "$val" in
            \"*\") val=${val:1:-1} ;;
            \'*\') val=${val:1:-1} ;;
        esac
        echo "$val"
    }

    EXISTING_SCANNER_DEVICE=$(read_var SCANNER_DEVICE  "$ENV_FILE")
    EXISTING_COLOR_DETECT=$(read_var COLOR_DETECT      "$ENV_FILE")
    EXISTING_URL=$(read_var PAPERLESS_URL              "$ENV_FILE")
    EXISTING_TOKEN=$(read_var PAPERLESS_TOKEN          "$ENV_FILE")
    EXISTING_CA=$(read_var PAPERLESS_CA                "$ENV_FILE")
    EXISTING_CONSUME_DIR=$(read_var PAPERLESS_CONSUME_DIR "$ENV_FILE")
    # Migration: older installs stored Paperless creds in paperless.conf
    if [ -f "$OLD_ENV_FILE" ]; then
        [ -z "$EXISTING_URL" ]   && EXISTING_URL=$(read_var PAPERLESS_URL  "$OLD_ENV_FILE")
        [ -z "$EXISTING_TOKEN" ] && EXISTING_TOKEN=$(read_var PAPERLESS_TOKEN "$OLD_ENV_FILE")
    fi

    # Derive existing mode from which vars are populated
    EXISTING_MODE=""
    if [ -n "$EXISTING_URL" ] && [ -n "$EXISTING_TOKEN" ]; then
        EXISTING_MODE=paperless-api
    elif [ -n "$EXISTING_CONSUME_DIR" ]; then
        EXISTING_MODE=paperless-folder
    elif [ -f "$ENV_FILE" ] || [ -f "$OLD_ENV_FILE" ]; then
        EXISTING_MODE=local
    fi

    QUICK_INSTALL=false
    if [ -n "$EXISTING_MODE" ]; then
        ok "Existing installation detected ($ENV_FILE)"
        case "$EXISTING_MODE" in
            paperless-api)    echo "    mode:    Paperless-ngx API ($EXISTING_URL)" ;;
            paperless-folder) echo "    mode:    Paperless-ngx folder ($EXISTING_CONSUME_DIR)" ;;
            local)            echo "    mode:    Local OCR" ;;
        esac
        [ -n "$EXISTING_SCANNER_DEVICE" ] && echo "    scanner: $EXISTING_SCANNER_DEVICE"
        [ -n "$EXISTING_COLOR_DETECT" ]   && echo "    color:   $EXISTING_COLOR_DETECT"
        echo
        read -rp "Keep current values? [Y/n]: " KEEP_CURRENT
        echo
        if [ "$KEEP_CURRENT" != "n" ] && [ "$KEEP_CURRENT" != "N" ]; then
            QUICK_INSTALL=true
            MODE="$EXISTING_MODE"
            SCANNER_DEVICE="$EXISTING_SCANNER_DEVICE"
            COLOR_DETECT="${EXISTING_COLOR_DETECT:-true}"
            PAPERLESS_URL="$EXISTING_URL"
            PAPERLESS_TOKEN="$EXISTING_TOKEN"
            PAPERLESS_CA="$EXISTING_CA"
            PAPERLESS_CONSUME_DIR="$EXISTING_CONSUME_DIR"
        else
            echo "Reconfiguring — press Enter at any prompt to keep the current value."
            echo
        fi
    fi

    # --- Mode selection ---
    if [ "$QUICK_INSTALL" = "false" ]; then
        echo "Select scanning mode:"
        echo "  1) Paperless-ngx API     - Upload scans to Paperless via API (recommended)"
        echo "  2) Paperless-ngx folder  - Write scans to Paperless consume folder"
        echo "  3) Local                 - OCR locally, save to ~/Documents/scanner-inbox/"
        echo

        DEFAULT_MODE_NUM=1
        case "$EXISTING_MODE" in
            paperless-folder) DEFAULT_MODE_NUM=2 ;;
            local)            DEFAULT_MODE_NUM=3 ;;
        esac

        read -rp "Choice [1/2/3] (default: $DEFAULT_MODE_NUM): " MODE_CHOICE
        MODE_CHOICE="${MODE_CHOICE:-$DEFAULT_MODE_NUM}"
        echo

        case "$MODE_CHOICE" in
            2) MODE=paperless-folder ;;
            3) MODE=local ;;
            *) MODE=paperless-api ;;
        esac
    fi

    # --- Dependency check ---
    echo "Checking dependencies..."
    DEPS_OK=true

    check_cmd scanimage "sane-backends" || DEPS_OK=false
    check_cmd magick "" || DEPS_OK=false

    if [ "$MODE" = "local" ]; then
        check_cmd ocrmypdf "" || DEPS_OK=false
        check_cmd tesseract "" || DEPS_OK=false
        if command -v tesseract &>/dev/null; then
            if tesseract --list-langs 2>/dev/null | grep -q "^nld$"; then
                ok "tesseract language: nld"
            else
                fail "tesseract language: nld missing"
                DEPS_OK=false
            fi
        fi
    fi

    if [ "$MODE" = "paperless-api" ]; then
        check_cmd curl "curl" || DEPS_OK=false
    fi

    # Notification dependencies
    check_cmd notify-send "libnotify" || DEPS_OK=false
    check_cmd xdg-open "xdg-utils" || DEPS_OK=false
    check_cmd xdg-terminal-exec "" || DEPS_OK=false

    echo

    if [ "$DEPS_OK" = false ]; then
        echo "Missing dependencies. Install them with:"
        [ ${#MISSING_SYSTEM[@]} -gt 0 ] && echo "  sudo dnf install ${MISSING_SYSTEM[*]}"
        echo
        read -rp "Continue anyway? [y/N]: " CONTINUE
        [ "$CONTINUE" != "y" ] && exit 1
        echo
    fi

    # --- Scanner detection ---
    # Stop the polling service first — it holds a tight `scanimage -A` loop on
    # the USB device, which makes `scanimage -L` return nothing. It is started
    # again at the end, or by the trap below if the install stops early.
    SERVICE_WAS_ACTIVE=false
    systemctl --user is-active --quiet snaphatch.service 2>/dev/null && SERVICE_WAS_ACTIVE=true
    RESTART_ON_EXIT=$SERVICE_WAS_ACTIVE
    trap '[ "$RESTART_ON_EXIT" = true ] && systemctl --user start --no-block snaphatch.service 2>/dev/null; true' EXIT
    systemctl --user stop snaphatch.service 2>/dev/null || true

    echo "Detecting scanner..."
    mapfile -t DETECTED_DEVICES < <(scanimage -L 2>/dev/null | grep -oP "fujitsu:ScanSnap [^:]+:\d+" || true)

    # The quick path keeps the saved device only if it is still there (or no
    # scanner is connected right now, so there is nothing to check against)
    CHOOSE_DEVICE=true
    if [ "$QUICK_INSTALL" = "true" ]; then
        CHOOSE_DEVICE=false
        if [ -n "$SCANNER_DEVICE" ] && [ "${#DETECTED_DEVICES[@]}" -gt 0 ] \
            && ! printf '%s\n' "${DETECTED_DEVICES[@]}" | grep -qxF -- "$SCANNER_DEVICE"; then
            warn "Saved scanner ($SCANNER_DEVICE) not detected, choose again."
            CHOOSE_DEVICE=true
        elif [ -n "$SCANNER_DEVICE" ] && [ "${#DETECTED_DEVICES[@]}" -eq 0 ]; then
            warn "No scanner connected; keeping the saved one ($SCANNER_DEVICE)."
        else
            ok "Scanner: ${SCANNER_DEVICE:-auto-detect at scan time}"
        fi
    elif [ -n "$EXISTING_SCANNER_DEVICE" ] && [ "${#DETECTED_DEVICES[@]}" -gt 0 ] \
        && ! printf '%s\n' "${DETECTED_DEVICES[@]}" | grep -qxF -- "$EXISTING_SCANNER_DEVICE"; then
        warn "Saved scanner ($EXISTING_SCANNER_DEVICE) not detected."
    fi

    if [ "$CHOOSE_DEVICE" = "true" ]; then
        SCANNER_DEVICE=""
        if [ "${#DETECTED_DEVICES[@]}" -eq 1 ]; then
            marker=""
            [ "${DETECTED_DEVICES[0]}" = "$EXISTING_SCANNER_DEVICE" ] && marker=" (current)"
            ok "Found: ${DETECTED_DEVICES[0]}$marker"
            read -rp "  Use this device? [Y/n]: " USE_DETECTED
            if [ "$USE_DETECTED" = "n" ] || [ "$USE_DETECTED" = "N" ]; then
                read -rp "  Device string: " SCANNER_DEVICE
            else
                SCANNER_DEVICE="${DETECTED_DEVICES[0]}"
            fi
        elif [ "${#DETECTED_DEVICES[@]}" -gt 1 ]; then
            ok "Found ${#DETECTED_DEVICES[@]} ScanSnap devices:"
            DEFAULT_DEV_IDX=1
            for i in "${!DETECTED_DEVICES[@]}"; do
                marker=""
                if [ "${DETECTED_DEVICES[$i]}" = "$EXISTING_SCANNER_DEVICE" ]; then
                    marker=" (current)"
                    DEFAULT_DEV_IDX=$((i + 1))
                fi
                echo "    $((i + 1))) ${DETECTED_DEVICES[$i]}$marker"
            done
            while true; do
                read -rp "  Choose device [1-${#DETECTED_DEVICES[@]}] (default: $DEFAULT_DEV_IDX): " CHOICE
                CHOICE="${CHOICE:-$DEFAULT_DEV_IDX}"
                if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#DETECTED_DEVICES[@]}" ]; then
                    break
                fi
                fail "Enter a number from 1 to ${#DETECTED_DEVICES[@]}"
            done
            SCANNER_DEVICE="${DETECTED_DEVICES[$((CHOICE - 1))]}"
        else
            warn "No ScanSnap detected"
            # Distinguish between "not connected" and "connected but SANE can't use it"
            if lsusb -d 04c5: 2>/dev/null | grep -qi "ScanSnap"; then
                warn "A ScanSnap is connected over USB, but SANE's fujitsu backend can't use it."
                warn "Check that the model is supported by sane-backends' fujitsu backend,"
                warn "and that no other program is using the scanner."
            else
                warn "Is it connected and powered on?"
            fi
            if [ -n "$EXISTING_SCANNER_DEVICE" ]; then
                read -rp "  Device string [$EXISTING_SCANNER_DEVICE]: " SCANNER_DEVICE
                SCANNER_DEVICE="${SCANNER_DEVICE:-$EXISTING_SCANNER_DEVICE}"
            else
                read -rp "  Enter device string manually, or leave blank to auto-detect at scan time: " SCANNER_DEVICE
            fi
        fi
    fi
    echo

    # --- Color detection preference ---
    if [ "$QUICK_INSTALL" = "false" ]; then
        echo "Auto color detection converts grayscale pages to reduce file size."
        if [ "$EXISTING_COLOR_DETECT" = "false" ]; then
            COLOR_PROMPT="y/N"
            COLOR_DEFAULT=false
        else
            COLOR_PROMPT="Y/n"
            COLOR_DEFAULT=true
        fi
        read -rp "Enable auto color detection? [$COLOR_PROMPT]: " COLOR_CHOICE

        if [ -z "$COLOR_CHOICE" ]; then
            COLOR_DETECT=$COLOR_DEFAULT
        elif [ "$COLOR_CHOICE" = "n" ] || [ "$COLOR_CHOICE" = "N" ]; then
            COLOR_DETECT=false
        else
            COLOR_DETECT=true
        fi
        echo
    fi

    # --- Mode-specific configuration (uses EXISTING_* defaults loaded above) ---
    # Quick-install already populated PAPERLESS_* from EXISTING_*; reset only when reconfiguring.
    if [ "$QUICK_INSTALL" = "false" ]; then
        PAPERLESS_URL=""
        PAPERLESS_TOKEN=""
        PAPERLESS_CA=""
        PAPERLESS_CONSUME_DIR=""
    fi

    if [ "$MODE" = "paperless-api" ] && [ "$QUICK_INSTALL" = "false" ]; then
        echo "Paperless-ngx API configuration:"

        if [ -n "$EXISTING_URL" ]; then
            read -rp "  URL [$EXISTING_URL]: " PAPERLESS_URL
            PAPERLESS_URL="${PAPERLESS_URL:-$EXISTING_URL}"
        else
            read -rp "  URL (e.g. https://paperless.example.com): " PAPERLESS_URL
        fi

        if [ -n "$EXISTING_TOKEN" ]; then
            read -rp "  API token [****${EXISTING_TOKEN: -4}]: " PAPERLESS_TOKEN
            PAPERLESS_TOKEN="${PAPERLESS_TOKEN:-$EXISTING_TOKEN}"
        else
            read -rp "  API token: " PAPERLESS_TOKEN
        fi

        if [ -z "$PAPERLESS_URL" ] || [ -z "$PAPERLESS_TOKEN" ]; then
            echo "Error: URL and token are required for Paperless API mode"
            exit 1
        fi

        # CA certificate for a Paperless behind a private CA (e.g. Caddy's internal CA)
        read -rp "  CA certificate file, blank for system trust [${EXISTING_CA:-none}]: " PAPERLESS_CA
        PAPERLESS_CA="${PAPERLESS_CA:-$EXISTING_CA}"
        if [ -n "$PAPERLESS_CA" ] && [ ! -f "$PAPERLESS_CA" ]; then
            warn "$PAPERLESS_CA does not exist"
        fi
        CA_ARGS=()
        [ -n "$PAPERLESS_CA" ] && CA_ARGS=(--cacert "$PAPERLESS_CA")

        # Test connection
        echo -n "  Testing connection... "
        HTTP_CODE=$(curl -s "${CA_ARGS[@]}" -o /dev/null -w "%{http_code}" --connect-timeout 5 \
            -H "Authorization: Token $PAPERLESS_TOKEN" \
            "$PAPERLESS_URL/api/documents/?page_size=1" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            ok "connected"
        else
            warn "could not verify (HTTP $HTTP_CODE) - continuing anyway"
        fi
        echo

    elif [ "$MODE" = "paperless-folder" ] && [ "$QUICK_INSTALL" = "false" ]; then
        echo "Paperless-ngx consume folder configuration:"

        if [ -n "$EXISTING_CONSUME_DIR" ]; then
            read -rp "  Consume folder [$EXISTING_CONSUME_DIR]: " PAPERLESS_CONSUME_DIR
            PAPERLESS_CONSUME_DIR="${PAPERLESS_CONSUME_DIR:-$EXISTING_CONSUME_DIR}"
        else
            read -rp "  Consume folder (e.g. /mnt/paperless-consume): " PAPERLESS_CONSUME_DIR
        fi

        if [ -z "$PAPERLESS_CONSUME_DIR" ]; then
            echo "Error: Consume folder path is required for Paperless folder mode"
            exit 1
        fi

        if [ ! -d "$PAPERLESS_CONSUME_DIR" ]; then
            warn "Directory $PAPERLESS_CONSUME_DIR does not exist (make sure it's available at scan time)"
        else
            ok "Directory exists"
        fi
        echo
    fi

    # --- Write config file ---
    # Settings the installer doesn't manage (e.g. BLANK_THRESHOLD, JPEG_QUALITY)
    # are kept as they are, and pushed to the service below with the others
    MANAGED_VARS="SCANNER_DEVICE|COLOR_DETECT|PAPERLESS_URL|PAPERLESS_TOKEN|PAPERLESS_CA|PAPERLESS_CONSUME_DIR"
    KEPT_LINES=()
    if [ -f "$ENV_FILE" ]; then
        mapfile -t KEPT_LINES < <(grep -vE "^(${MANAGED_VARS})=|^# (Scanner|snaphatch) configuration" "$ENV_FILE" || true)
    fi
    mkdir -p "$ENV_DIR"
    # Holds the Paperless token: readable by you only, also while writing
    ( umask 077; : > "$ENV_FILE" )
    chmod 600 "$ENV_FILE"
    {
        echo "# snaphatch configuration (see README)"
        echo "SCANNER_DEVICE=$SCANNER_DEVICE"
        echo "COLOR_DETECT=$COLOR_DETECT"
        if [ "$MODE" = "paperless-api" ]; then
            echo "PAPERLESS_URL=$PAPERLESS_URL"
            echo "PAPERLESS_TOKEN=$PAPERLESS_TOKEN"
            [ -n "$PAPERLESS_CA" ] && echo "PAPERLESS_CA=$PAPERLESS_CA"
        elif [ "$MODE" = "paperless-folder" ]; then
            echo "PAPERLESS_CONSUME_DIR=$PAPERLESS_CONSUME_DIR"
        fi
        [ "${#KEPT_LINES[@]}" -gt 0 ] && printf '%s\n' "${KEPT_LINES[@]}"
    } > "$ENV_FILE"
    ok "Saved settings to $ENV_FILE"

    # Remove old paperless.conf if it exists
    if [ -f "$OLD_ENV_FILE" ]; then
        rm "$OLD_ENV_FILE"
        ok "Migrated from paperless.conf → scanner.conf"
    fi
    echo

    # --- Install files ---
    echo "Installing..."
    SCRIPT_DIR="{{justfile_directory()}}"
    # Overridable so the tests never touch the host's /etc
    UDEV_RULES_DIR="${SNAPHATCH_UDEV_DIR:-/etc/udev/rules.d}"

    LIB_DIR="$HOME/.local/lib/snaphatch"
    mkdir -p "$LIB_DIR"
    install -m 0755 "$SCRIPT_DIR/snaphatch" "$SCRIPT_DIR/snaphatch-scan" "$SCRIPT_DIR/snaphatch-poll" "$LIB_DIR/"
    install -m 0644 "$SCRIPT_DIR/snaphatch-config.sh" "$LIB_DIR/"
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$LIB_DIR/snaphatch" "$HOME/.local/bin/snaphatch"
    ok "Scripts installed to ~/.local/lib/snaphatch/, command ~/.local/bin/snaphatch"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) warn "~/.local/bin is not on your PATH: add it to run snaphatch" ;;
    esac

    mkdir -p "$HOME/.config/systemd/user"
    cp "$SCRIPT_DIR/snaphatch.service" "$HOME/.config/systemd/user/"
    ok "Systemd service installed"

    echo
    echo "Installing udev rules (requires sudo)..."
    RULES_DEST="$UDEV_RULES_DIR/99-snaphatch.rules"
    sudo install -m 0644 "$SCRIPT_DIR/99-snaphatch.rules" "$RULES_DEST"
    ok "Udev rules installed to $RULES_DEST"

    # Clean up rules file from older install that used a model-specific name
    if [ -f "$UDEV_RULES_DIR/99-scansnap-ix500.rules" ]; then
        sudo rm "$UDEV_RULES_DIR/99-scansnap-ix500.rules"
        ok "Removed old 99-scansnap-ix500.rules"
    fi

    # --- Activate ---
    echo
    echo "Activating..."

    # No need to push settings into the systemd session: the service reads
    # the config file (EnvironmentFile=) every time it starts
    systemctl --user daemon-reload
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    sudo udevadm settle
    ok "Systemd and udev reloaded"

    # The service is bound to the scanner (BindsTo=dev-scansnap.device), so
    # only start it when one is connected; otherwise udev starts it later
    RESTART_ON_EXIT=false
    if systemctl --user is-active --quiet dev-scansnap.device 2>/dev/null; then
        systemctl --user restart snaphatch.service 2>/dev/null && \
            ok "Service started" || \
            warn "Service did not start, see: snaphatch logs"
    else
        warn "No scanner connected: the service starts when you connect it"
    fi

    echo
    echo "Installation complete!"
    case "$MODE" in
        paperless-api)    echo "Scans will be uploaded to Paperless at $PAPERLESS_URL" ;;
        paperless-folder) echo "Scans will be saved to $PAPERLESS_CONSUME_DIR" ;;
        local)            echo "Scans will be saved to $(xdg-user-dir DOCUMENTS 2>/dev/null || echo ~/Documents)/snaphatch/" ;;
    esac
    echo
    echo "Press the scan button, or run: snaphatch scan [name]"
    echo "Service: snaphatch status, snaphatch logs, snaphatch restart"

# Check dependencies for all modes
check:
    #!/usr/bin/env bash
    set -e

    GREEN='\033[0;32m'
    RED='\033[0;31m'
    NC='\033[0m'

    ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
    fail() { echo -e "  ${RED}✗${NC} $1"; }
    ALL_OK=true

    check_cmd() {
        if command -v "$1" &>/dev/null; then
            ok "$1 found: $(command -v "$1")"
        else
            fail "$1 not found"
            ALL_OK=false
        fi
    }

    echo "Core dependencies:"
    check_cmd scanimage
    check_cmd magick

    echo
    echo "Notification dependencies:"
    check_cmd notify-send
    check_cmd xdg-open
    check_cmd xdg-terminal-exec

    echo
    echo "Paperless API mode:"
    check_cmd curl

    echo
    echo "Local mode:"
    check_cmd ocrmypdf
    check_cmd tesseract
    if command -v tesseract &>/dev/null; then
        if tesseract --list-langs 2>/dev/null | grep -q "^nld$"; then
            ok "tesseract language: nld"
        else
            fail "tesseract language: nld missing"
            ALL_OK=false
        fi
    fi

    echo
    if [ "$ALL_OK" = true ]; then
        echo "All dependencies found."
    else
        echo "Some dependencies are missing (not all may be needed for your mode)."
    fi

# Run the tests (no scanner or network needed; uses magick and pdfimages)
test:
    bash tests/test-scan.sh
    bash tests/test-upload.sh
    bash tests/test-poll.sh
    bash tests/test-install.sh
    bash tests/test-cli.sh

# Remove installed files, service, and udev rules
uninstall:
    #!/usr/bin/env bash
    set -e

    GREEN='\033[0;32m'
    NC='\033[0m'
    ok() { echo -e "  ${GREEN}✓${NC} $1"; }

    echo "Uninstalling snaphatch..."
    echo

    # Stop and disable service
    systemctl --user stop snaphatch.service 2>/dev/null && ok "Service stopped" || true

    # Remove scripts
    rm -rf "$HOME/.local/lib/snaphatch"
    ok "Scripts removed from ~/.local/lib/snaphatch/"

    # Remove service file
    rm -f "$HOME/.config/systemd/user/snaphatch.service"
    ok "Systemd service removed"

    # Remove udev rules (includes older model-specific filename for upgrades)
    echo
    echo "Removing udev rules (requires sudo)..."
    UDEV_RULES_DIR="${SNAPHATCH_UDEV_DIR:-/etc/udev/rules.d}"
    sudo rm -f "$UDEV_RULES_DIR/99-snaphatch.rules"
    ok "Udev rules removed"

    # Reload
    systemctl --user daemon-reload
    sudo udevadm control --reload-rules
    ok "Systemd and udev reloaded"

    echo
    echo "Uninstalled. Config file ~/.config/environment.d/scanner.conf was kept (delete manually if desired)."
