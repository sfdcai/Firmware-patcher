#!/bin/sh
# Inventory utility for enumerating available commands and their versions on OpenWrt-like systems.
#
# The script is intentionally POSIX-compliant so it can run on lightweight router environments
# that only ship BusyBox.  It scans the current PATH (unless disabled) and records every
# executable it discovers, attempts to execute the most common version flags, and reports the
# resolved binary path alongside the detected version string.  When commands are provided via
# arguments or a file, those entries are merged with the PATH scan to build a single, sorted list.
#
# Usage:
#   router_command_inventory.sh [options]
#
# Options:
#   -c, --command <name>   Add an explicit command to probe (may be provided multiple times).
#   -f, --file <path>      Load additional command names from a file (one per line).
#   -n, --no-path-scan     Skip scanning $PATH; only use commands provided via -c/-f.
#   -o, --output <path>    Write the report to the given file instead of stdout.
#   -h, --help             Display this help text and exit.
#
# Exit status:
#   0 on success, non-zero on error.
#
# The script is safe to run repeatedly.  It writes to temporary files that are cleaned up on exit
# and never mutates system configuration.

set -eu

usage() {
    cat <<'USAGE'
Usage: router_command_inventory.sh [options]

Options:
  -c, --command <name>   Add an explicit command to probe (may be repeated).
  -f, --file <path>      Load additional command names from a file (one per line).
  -n, --no-path-scan     Do not scan $PATH; only use commands provided explicitly.
  -o, --output <path>    Write the report to the specified file.
  -h, --help             Show this help and exit.

The report lists each command name, the resolved executable path, and the best-effort
version string.  BusyBox applets inherit the BusyBox version.
USAGE
}

OUTPUT_FILE=""
NO_PATH_SCAN=0
COMMAND_LIST=""
COMMAND_FILE=""

# Parse arguments.
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c|--command)
            if [ "$#" -lt 2 ]; then
                echo "Missing argument for $1" >&2
                exit 1
            fi
            COMMAND_LIST="$COMMAND_LIST
$2"
            shift 2
            ;;
        -f|--file)
            if [ "$#" -lt 2 ]; then
                echo "Missing argument for $1" >&2
                exit 1
            fi
            COMMAND_FILE="$2"
            shift 2
            ;;
        -n|--no-path-scan)
            NO_PATH_SCAN=1
            shift
            ;;
        -o|--output)
            if [ "$#" -lt 2 ]; then
                echo "Missing argument for $1" >&2
                exit 1
            fi
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            # Positional arguments are treated as commands.
            COMMAND_LIST="$COMMAND_LIST
$1"
            shift
            ;;
    esac
done

TMP_COMMANDS="$(mktemp -t command_inventory.XXXXXX)"
TMP_SORTED="$(mktemp -t command_inventory_sorted.XXXXXX)"
TMP_RESULTS="$(mktemp -t command_inventory_results.XXXXXX)"
BUSYBOX_APPLETS_FILE=""

cleanup() {
    rm -f "$TMP_COMMANDS" "$TMP_SORTED" "$TMP_RESULTS"
    [ -z "$BUSYBOX_APPLETS_FILE" ] || rm -f "$BUSYBOX_APPLETS_FILE"
    [ -z "$BUSYBOX_APPLETS_NAMES" ] || rm -f "$BUSYBOX_APPLETS_NAMES"
}
trap cleanup INT TERM EXIT

# Collect commands from PATH.
if [ "$NO_PATH_SCAN" -eq 0 ]; then
    IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || continue
        if [ -d "$dir" ]; then
            for entry in "$dir"/*; do
                [ -e "$entry" ] || continue
                if [ -f "$entry" ] || [ -L "$entry" ]; then
                    if [ -x "$entry" ]; then
                        basename "$entry" >>"$TMP_COMMANDS"
                    fi
                fi
            done
        fi
    done
    unset IFS
fi

# Include commands passed via CLI options.
if [ -n "$COMMAND_LIST" ]; then
    echo "$COMMAND_LIST" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$line" >>"$TMP_COMMANDS"
    done
fi

# Include commands from file if provided.
if [ -n "$COMMAND_FILE" ]; then
    if [ ! -r "$COMMAND_FILE" ]; then
        echo "Command list file not readable: $COMMAND_FILE" >&2
        exit 1
    fi
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*)
                continue
                ;;
            *)
                printf '%s\n' "$line" >>"$TMP_COMMANDS"
                ;;
        esac
    done <"$COMMAND_FILE"
fi

# De-duplicate and sort command names.
if ! sort -u "$TMP_COMMANDS" >"$TMP_SORTED"; then
    echo "Failed to sort command list" >&2
    exit 1
fi

BUSYBOX_PATH=""
BUSYBOX_VERSION=""
BUSYBOX_APPLETS_FILE=""
BUSYBOX_APPLETS_NAMES=""
BUSYBOX_APPLETS_COUNT="0"
if command -v busybox >/dev/null 2>&1; then
    BUSYBOX_PATH="$(command -v busybox)"
    # Attempt to grab the version from the first line of `busybox` output.
    set +e
    BUSYBOX_VERSION_OUTPUT="$($BUSYBOX_PATH 2>&1)"
    BUSYBOX_STATUS=$?
    set -e
    if [ "$BUSYBOX_STATUS" -eq 0 ] && [ -n "$BUSYBOX_VERSION_OUTPUT" ]; then
        BUSYBOX_VERSION="$(printf '%s\n' "$BUSYBOX_VERSION_OUTPUT" | head -n 1 | tr -d '\r')"
    fi
    set +e
    BUSYBOX_APPLETS_OUTPUT="$($BUSYBOX_PATH --list-full 2>/dev/null)"
    BUSYBOX_APPLETS_STATUS=$?
    set -e
    if [ "$BUSYBOX_APPLETS_STATUS" -eq 0 ] && [ -n "$BUSYBOX_APPLETS_OUTPUT" ]; then
        BUSYBOX_APPLETS_FILE="$(mktemp -t busybox_applets.XXXXXX)"
        printf '%s\n' "$BUSYBOX_APPLETS_OUTPUT" >"$BUSYBOX_APPLETS_FILE"
        BUSYBOX_APPLETS_NAMES="$(mktemp -t busybox_applets_names.XXXXXX)"
        awk -F'/' '{print $NF}' "$BUSYBOX_APPLETS_FILE" | sort -u >"$BUSYBOX_APPLETS_NAMES"
        BUSYBOX_APPLETS_COUNT="$(printf '%s\n' "$BUSYBOX_APPLETS_OUTPUT" | wc -l 2>/dev/null || printf '0')"
    fi
fi

report_line() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$TMP_RESULTS"
}

probe_version() {
    cmd_name="$1"
    cmd_path="$2"
    version=""
    for flag in --version -V -v; do
        set +e
        output="$($cmd_path "$flag" 2>&1)"
        status=$?
        set -e
        if [ "$status" -eq 0 ] && [ -n "$output" ]; then
            version_line="$(printf '%s\n' "$output" | head -n 1 | tr -d '\r')"
            if [ -n "$version_line" ]; then
                version="$version_line"
                break
            fi
        fi
    done
    if [ -z "$version" ] && [ -n "$BUSYBOX_PATH" ]; then
        if [ "$cmd_name" = "busybox" ]; then
            version="$BUSYBOX_VERSION"
        elif [ -n "$BUSYBOX_APPLETS_NAMES" ] && grep -Fx "$cmd_name" "$BUSYBOX_APPLETS_NAMES" >/dev/null 2>&1; then
            if [ -n "$BUSYBOX_VERSION" ]; then
                version="$BUSYBOX_VERSION (busybox applet)"
            else
                version="busybox applet"
            fi
        fi
    fi
    if [ -z "$version" ]; then
        version="unknown"
    fi
    printf '%s\n' "$version"
}

now="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"

if [ -n "$OUTPUT_FILE" ]; then
    output_dir="$(dirname "$OUTPUT_FILE")"
    if [ -n "$output_dir" ] && [ "$output_dir" != "." ] && [ ! -d "$output_dir" ]; then
        echo "Creating output directory $output_dir"
        mkdir -p "$output_dir"
    fi
fi

while IFS= read -r command_name; do
    [ -n "$command_name" ] || continue
    if ! command -v "$command_name" >/dev/null 2>&1; then
        report_line "$command_name" "(not found)" "missing"
        continue
    fi
    resolved_path="$(command -v "$command_name")"
    version_string="$(probe_version "$command_name" "$resolved_path")"
    report_line "$command_name" "$resolved_path" "$version_string"

done <"$TMP_SORTED"

HEADER="Router command inventory generated on $now"
SEPARATOR="----------------------------------------------------------------------"

output_report() {
    printf '%s\n' "$HEADER"
    if [ -n "$BUSYBOX_PATH" ]; then
        if [ -n "$BUSYBOX_VERSION" ]; then
            printf 'BusyBox: %s\n' "$BUSYBOX_VERSION"
        else
            printf 'BusyBox: %s\n' "$BUSYBOX_PATH"
        fi
        printf 'BusyBox applets: %s\n' "$BUSYBOX_APPLETS_COUNT"
    fi
    printf '%s\n' "$SEPARATOR"
    printf '%-24s %-40s %s\n' "COMMAND" "RESOLVED PATH" "VERSION"
    printf '%s\n' "$SEPARATOR"
    while IFS='|' read -r name path version; do
        printf '%-24s %-40s %s\n' "$name" "$path" "$version"
    done <"$TMP_RESULTS"
}

if [ -n "$OUTPUT_FILE" ]; then
    output_report >"$OUTPUT_FILE"
    printf 'Report written to %s\n' "$OUTPUT_FILE"
else
    output_report
fi
