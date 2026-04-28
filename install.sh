#!/bin/bash
# ClaudeRestore installer.
# Idempotent: re-running updates symlinks and re-merges hooks safely.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Installing ClaudeRestore ==="

# ── Dependency check ──────────────────────────────────────────────────────────
for dep in jq journalctl; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "ERROR: '$dep' is required but not installed." >&2
        exit 1
    fi
done

# ── PATH binary ───────────────────────────────────────────────────────────────
mkdir -p ~/.local/bin
ln -sf "$SCRIPT_DIR/bin/cr" ~/.local/bin/cr
echo "  ✓ Symlinked cr → ~/.local/bin/cr"

# ── Registry directory ────────────────────────────────────────────────────────
mkdir -p ~/.claude/active-sessions
chmod 700 ~/.claude/active-sessions
echo "  ✓ Registry dir at ~/.claude/active-sessions"

# ── Merge hooks into ~/.claude/settings.json ──────────────────────────────────
SETTINGS=~/.claude/settings.json
if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

START_HOOK="$SCRIPT_DIR/hooks/session-start.sh"
END_HOOK="$SCRIPT_DIR/hooks/session-end.sh"

# Add SessionStart and SessionEnd hooks idempotently (skip if already present
# pointing at our scripts).
tmp="$(mktemp)"
jq \
    --arg starthook "$START_HOOK" \
    --arg endhook "$END_HOOK" \
    '
    .hooks //= {}
    | .hooks.SessionStart //= []
    | .hooks.SessionEnd //= []
    | .hooks.SessionStart |= (
        if any(.[]?; (.hooks // []) | any(.command == $starthook)) then .
        else . + [{ "hooks": [{ "type": "command", "command": $starthook }] }]
        end
    )
    | .hooks.SessionEnd |= (
        if any(.[]?; (.hooks // []) | any(.command == $endhook)) then .
        else . + [{ "hooks": [{ "type": "command", "command": $endhook }] }]
        end
    )
    ' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"
echo "  ✓ Hooks registered in ~/.claude/settings.json"

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<EOF

=== Installation complete ===

Next steps:
  1. Make sure ~/.local/bin is on your PATH (it should be already).
  2. Route your claude aliases through the wrapper. Either:
       • Run:  $SCRIPT_DIR/scripts/migrate-aliases.sh
       • Or edit ~/.bash_aliases manually, replacing 'claude' with 'cr wrap'
         in lines like:  alias c='claude'  →  alias c='cr wrap'
     Then: source ~/.bash_aliases  (or open a new terminal)

Usage:
  cr               Auto-restore previous-boot sessions (skips already-live ones)
  cr restore       Interactive picker
  cr status        Show registry
  cr clean         GC stale entries
  cr help          Full help

EOF
