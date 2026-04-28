#!/bin/bash
# ClaudeRestore uninstaller.
# Removes symlinks and hook entries; preserves the repo and registry data.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Uninstalling ClaudeRestore ==="

# ── Remove PATH symlink ───────────────────────────────────────────────────────
if [ -L ~/.local/bin/cr ]; then
    rm -f ~/.local/bin/cr
    echo "  ✓ Removed ~/.local/bin/cr"
fi

# ── Remove hook entries ───────────────────────────────────────────────────────
SETTINGS=~/.claude/settings.json
START_HOOK="$SCRIPT_DIR/hooks/session-start.sh"
END_HOOK="$SCRIPT_DIR/hooks/session-end.sh"

if [ -f "$SETTINGS" ]; then
    tmp="$(mktemp)"
    jq \
        --arg starthook "$START_HOOK" \
        --arg endhook "$END_HOOK" \
        '
        if .hooks then
            .hooks.SessionStart = (
                (.hooks.SessionStart // [])
                | map(select((.hooks // []) | all(.command != $starthook)))
                | if length == 0 then null else . end
            )
            | .hooks.SessionEnd = (
                (.hooks.SessionEnd // [])
                | map(select((.hooks // []) | all(.command != $endhook)))
                | if length == 0 then null else . end
            )
            | .hooks |= with_entries(select(.value != null))
            | if (.hooks | length) == 0 then del(.hooks) else . end
        else . end
        ' "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "  ✓ Hook entries removed from ~/.claude/settings.json"
fi

# ── Optional: registry data ───────────────────────────────────────────────────
if [ -d ~/.claude/active-sessions ]; then
    read -p "Remove session registry at ~/.claude/active-sessions? (y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        rm -rf ~/.claude/active-sessions
        echo "  ✓ Registry removed"
    fi
fi

cat <<EOF

=== Uninstall complete ===

Note: this script does NOT touch ~/.bash_aliases. If you ran the alias
migration, revert it manually or via:
  $SCRIPT_DIR/scripts/migrate-aliases.sh --revert

Repo remains at: $SCRIPT_DIR
EOF
