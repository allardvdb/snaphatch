# snaphatch-config.sh - read the snaphatch config file (part of snaphatch)
#
# Sourced by snaphatch-scan and snaphatch-poll. The same file is read by
# snaphatch.service through EnvironmentFile=, so it holds plain KEY=value
# lines. It is parsed here, never sourced, so it can't run code.

# Settings snaphatch reads from the config file
SNAPHATCH_KEYS="SCANNER_DEVICE COLOR_DETECT PAPERLESS_URL PAPERLESS_TOKEN PAPERLESS_CA PAPERLESS_CONSUME_DIR BLANK_THRESHOLD JPEG_QUALITY"

# load_config [FILE] - export the known settings from FILE (default: the
# snaphatch config) that are not already set in the environment, so a value
# given on the command line wins. Blank lines, comments, unknown keys and
# malformed lines are skipped; one pair of surrounding quotes is stripped.
load_config() {
    local file=${1:-${SNAPHATCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/snaphatch/snaphatch.conf}}
    local line key val
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        [[ " $SNAPHATCH_KEYS " == *" $key "* ]] || continue
        [ -z "${!key+set}" ] || continue
        case "$val" in
            \"*\") val=${val:1:-1} ;;
            \'*\') val=${val:1:-1} ;;
        esac
        export "$key=$val"
    done < "$file"
    return 0
}
