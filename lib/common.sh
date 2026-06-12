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

# Epoch of the user's most recent local-seat logind session start.
# Used to distinguish wrapper deaths within the current user-login (user closed
# the terminal — don't restore) from wrapper deaths that crossed a user-login
# boundary (X/Wayland crash, user-space restart — restore).
# Filters on non-empty Seat to exclude remote-desktop pseudo-sessions
# (chrome-remote-desktop, xrdp) that don't tear down our local terminals.
# Returns empty if loginctl is unavailable or no qualifying session exists —
# callers should fall back to "treat same-boot dead as restorable" in that case.
cr_user_login_epoch() {
    command -v loginctl >/dev/null 2>&1 || { echo ""; return 1; }
    local uid newest=0 sid sess_uid seat ts epoch
    uid="$(id -u)"
    while read -r sid _; do
        [ -z "$sid" ] && continue
        sess_uid="$(loginctl show-session "$sid" -p User --value 2>/dev/null)"
        [ "$sess_uid" = "$uid" ] || continue
        seat="$(loginctl show-session "$sid" -p Seat --value 2>/dev/null)"
        [ -n "$seat" ] || continue
        ts="$(loginctl show-session "$sid" -p Timestamp --value 2>/dev/null)"
        [ -n "$ts" ] || continue
        epoch="$(date -d "$ts" +%s 2>/dev/null)"
        [ -n "$epoch" ] && [ "$epoch" -gt "$newest" ] && newest=$epoch
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    [ "$newest" -gt 0 ] && echo "$newest" || echo ""
}

# Cached `journalctl --list-boots` output. Classification touches this once per
# registry entry (often 100+), so we resolve it a single time per command. The
# cache lives in the calling shell; command-substitution subshells inherit it.
cr_boots_list() {
    if [ -z "${CR_BOOTS_CACHE+x}" ]; then
        CR_BOOTS_CACHE="$(journalctl --list-boots 2>/dev/null)"
    fi
    printf '%s\n' "$CR_BOOTS_CACHE"
}

# Parse `journalctl --list-boots` plain-text output (json mode unsupported on systemd<252).
# Format: "IDX BOOT_ID Day YYYY-MM-DD HH:MM:SS TZ—Day YYYY-MM-DD HH:MM:SS TZ"
# Returns epoch seconds of the last entry for the given boot_id, or empty if not found.
cr_boot_last_entry_epoch() {
    local target="$1" line last_str
    line="$(cr_boots_list | awk -v b="$target" '$2 == b')"
    [ -z "$line" ] && { echo ""; return 1; }
    # Extract everything after the em-dash (—, U+2014).
    last_str="${line##*—}"
    # Trim leading whitespace.
    last_str="${last_str#"${last_str%%[![:space:]]*}"}"
    [ -z "$last_str" ] && { echo ""; return 1; }
    date -d "$last_str" +%s 2>/dev/null
}

# Recency rank of a boot: its `journalctl --list-boots` index (0 = current boot,
# -1 = immediately previous, -2 = before that, …). Higher = more recent. Empty
# if the boot has aged out of the journal (no anchor → never restorable).
cr_boot_rank() {
    local b="$1" current="$2" idx
    [ "$b" = "$current" ] && { echo 0; return 0; }
    idx="$(cr_boots_list | awk -v b="$b" '$2 == b {print $1; exit}')"
    [ -n "$idx" ] && echo "$idx"
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
