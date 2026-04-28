#!/bin/bash
# Claude Code SessionStart hook.
# Reads JSON on stdin, writes session registry entry, publishes session_id to handoff.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

input="$(cat)"
sid="$(echo "$input" | jq -r '.session_id // empty')"
cwd="$(echo "$input" | jq -r '.cwd // empty')"
source="$(echo "$input" | jq -r '.source // "unknown"')"

if [ -z "$sid" ]; then
    cr_log "SessionStart: missing session_id; aborting"
    exit 0
fi

# PPID of the hook is the claude process — same PID as the wrapper after exec.
wrapper_pid="$PPID"
wrapper_starttime="$(cr_pid_starttime "$wrapper_pid" || echo "")"
boot_id="$(cr_boot_id)"
terminal="$(cr_detect_terminal "$wrapper_pid")"
started_at="$(cr_now_iso)"

cr_ensure_registry
mkdir -p "$(cr_session_dir "$sid")"

tmp="$(mktemp)"
jq -n \
    --arg sid "$sid" \
    --arg cwd "$cwd" \
    --arg pid "$wrapper_pid" \
    --arg pid_starttime "$wrapper_starttime" \
    --arg boot_id "$boot_id" \
    --arg terminal "$terminal" \
    --arg started_at "$started_at" \
    --arg source "$source" \
    '{
        session_id:     $sid,
        cwd:            $cwd,
        pid:            ($pid | tonumber),
        pid_starttime:  (if $pid_starttime == "" then null else ($pid_starttime | tonumber) end),
        boot_id:        $boot_id,
        terminal:       $terminal,
        started_at:     $started_at,
        source:         $source
    }' > "$tmp"
mv "$tmp" "$(cr_session_info "$sid")"

# Initial heartbeat — file mtime is the signal.
touch "$(cr_session_heartbeat "$sid")"

# Publish session_id to the wrapper's handoff file so its heartbeat loop knows
# which session to keep warm. Skip silently if not run via wrapper.
if [ -n "$CR_HANDOFF" ] && [ -e "$CR_HANDOFF" ]; then
    echo "$sid" > "$CR_HANDOFF"
else
    cr_log "SessionStart: no CR_HANDOFF set (session $sid not run via 'cr wrap')"
fi

exit 0
