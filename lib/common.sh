#!/bin/bash
# Shared helpers for cr wrapper, hooks, and restore command.

CR_REGISTRY="${CR_REGISTRY:-$HOME/.claude/active-sessions}"
CR_HEARTBEAT_INTERVAL="${CR_HEARTBEAT_INTERVAL:-5}"
CR_RESTORE_THRESHOLD_SEC="${CR_RESTORE_THRESHOLD_SEC:-30}"
CR_LOG_TAG="${CR_LOG_TAG:-claude-restore}"

cr_log() {
    if command -v systemd-cat >/dev/null 2>&1; then
        echo "$*" | systemd-cat -t "$CR_LOG_TAG" -p info
    else
        echo "[$CR_LOG_TAG] $*" >&2
    fi
}

cr_boot_id() {
    tr -d '-' < /proc/sys/kernel/random/boot_id
}

cr_now_epoch() { date +%s; }
cr_now_iso()   { date --iso-8601=seconds; }

cr_pid_starttime() {
    local pid="$1"
    [ -r "/proc/$pid/stat" ] || { echo ""; return 1; }
    # Field 22 is starttime in clock ticks since boot.
    # Use sed to handle commands with spaces/parens (field 2 is "(comm)").
    sed -E 's/^[0-9]+ \(.*\) //' "/proc/$pid/stat" | awk '{print $20}'
}

cr_pid_alive() {
    local pid="$1" expected_starttime="$2"
    [ -d "/proc/$pid" ] || return 1
    if [ -n "$expected_starttime" ]; then
        local actual
        actual="$(cr_pid_starttime "$pid")" || return 1
        [ "$actual" = "$expected_starttime" ] || return 1
    fi
    return 0
}

cr_detect_terminal() {
    local pid="${1:-$$}" name parent
    while [ "$pid" -gt 1 ]; do
        [ -r "/proc/$pid/comm" ] || break
        name="$(cat "/proc/$pid/comm" 2>/dev/null)"
        case "$name" in
            kitty|alacritty|wezterm|wezterm-gui|konsole|xterm|urxvt|rxvt|st|terminator|tilix|gnome-terminal-|gnome-terminal-server|cosmic-term|cosmic-terminal|ghostty|foot)
                echo "$name"
                return 0
                ;;
        esac
        parent="$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
        [ -z "$parent" ] && break
        [ "$parent" = "$pid" ] && break
        pid="$parent"
    done
    echo "unknown"
}

# Parse `journalctl --list-boots` plain-text output (json mode unsupported on systemd<252).
# Format: "IDX BOOT_ID Day YYYY-MM-DD HH:MM:SS TZ—Day YYYY-MM-DD HH:MM:SS TZ"
# Returns epoch seconds of the last entry for the given boot_id, or empty if not found.
cr_boot_last_entry_epoch() {
    local target="$1" line last_str
    line="$(journalctl --list-boots 2>/dev/null | awk -v b="$target" '$2 == b')"
    [ -z "$line" ] && { echo ""; return 1; }
    # Extract everything after the em-dash (—, U+2014).
    last_str="${line##*—}"
    # Trim leading whitespace.
    last_str="${last_str#"${last_str%%[![:space:]]*}"}"
    [ -z "$last_str" ] && { echo ""; return 1; }
    date -d "$last_str" +%s 2>/dev/null
}

cr_ensure_registry() {
    mkdir -p "$CR_REGISTRY"
    chmod 700 "$CR_REGISTRY"
}

cr_session_dir()       { echo "$CR_REGISTRY/$1"; }
cr_session_info()      { echo "$CR_REGISTRY/$1/info.json"; }
cr_session_heartbeat() { echo "$CR_REGISTRY/$1/heartbeat"; }

# mtime (epoch) of a heartbeat file, or empty if missing.
cr_heartbeat_epoch() {
    local f="$1"
    [ -f "$f" ] || { echo ""; return 1; }
    stat -c %Y "$f" 2>/dev/null
}
