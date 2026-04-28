#!/bin/bash
# Claude Code SessionEnd hook.
# Removes the registry entry on clean exit (/exit, EOF, /clear, /resume to other).
# Note: does NOT fire on SIGHUP (window close) or SIGTERM (system shutdown);
# heartbeat staleness handles those cases at restore time.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

input="$(cat)"
sid="$(echo "$input" | jq -r '.session_id // empty')"

[ -z "$sid" ] && exit 0

dir="$(cr_session_dir "$sid")"
if [ -d "$dir" ]; then
    rm -rf "$dir"
fi

exit 0
