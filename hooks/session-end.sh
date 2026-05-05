#!/bin/bash
# Claude Code SessionEnd hook.
# Claude Code passes exit_reason ∈ {clear, resume, logout, prompt_input_exit,
# bypass_permissions_disabled, other}. We delete the registry entry on
# user-initiated ends (the session is genuinely over) but preserve it on
# `logout`, which is what fires when the desktop session shuts down on
# reboot — those entries must survive for next-boot `cr` to restore them.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

input="$(cat)"
sid="$(echo "$input" | jq -r '.session_id // empty')"
exit_reason="$(echo "$input" | jq -r '.exit_reason // ""')"

[ -z "$sid" ] && exit 0

case "$exit_reason" in
    logout)
        cr_log "SessionEnd: preserving $sid (exit_reason=logout — system shutdown/reboot)"
        exit 0
        ;;
    *)
        cr_log "SessionEnd: removing $sid (exit_reason=${exit_reason:-unset})"
        ;;
esac

dir="$(cr_session_dir "$sid")"
if [ -d "$dir" ]; then
    rm -rf "$dir"
fi

exit 0
