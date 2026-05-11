#!/bin/bash
# Claude Code SessionEnd hook.
# Claude Code passes exit_reason ∈ {clear, resume, logout, prompt_input_exit,
# bypass_permissions_disabled, other, ...}. We remove the registry entry only
# on explicit user-initiated reasons. Everything else (logout, other, empty,
# or any new value Claude may add) is preserved — `cr_classify` then decides
# restorability from PID liveness and the user-login boundary.
#
# Preserving aggressively is the safer default: stale entries are cheaply
# GC'd by `cr clean`, but a wrongly-removed entry is unrecoverable work.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

input="$(cat)"
sid="$(echo "$input" | jq -r '.session_id // empty')"
exit_reason="$(echo "$input" | jq -r '.exit_reason // ""')"

[ -z "$sid" ] && exit 0

case "$exit_reason" in
    clear|resume|prompt_input_exit|bypass_permissions_disabled)
        cr_log "SessionEnd: removing $sid (exit_reason=$exit_reason)"
        ;;
    *)
        cr_log "SessionEnd: preserving $sid (exit_reason=${exit_reason:-unset})"
        exit 0
        ;;
esac

dir="$(cr_session_dir "$sid")"
if [ -d "$dir" ]; then
    rm -rf "$dir"
fi

exit 0
