#!/bin/bash
# Optional helper: rewrite `claude` → `cr wrap` inside `alias` lines in
# ~/.bash_aliases (or a chosen file), so existing aliases route through the
# wrapper. Creates a timestamped backup and supports --revert.
#
# Only touches lines starting with `alias `. Within those lines, replaces
# the bare command `claude` (preceded by ' or && or beginning, followed by
# ' or whitespace) with `cr wrap`. Paths/words containing 'claude' are not
# affected.

set -e

TARGET="${1:-$HOME/.bash_aliases}"
ACTION="${ACTION:-migrate}"
[ "${1:-}" = "--revert" ] && { ACTION=revert; TARGET="${2:-$HOME/.bash_aliases}"; }
[ "${2:-}" = "--revert" ] && ACTION=revert

if [ ! -f "$TARGET" ]; then
    echo "ERROR: $TARGET not found." >&2
    exit 1
fi

case "$ACTION" in
    migrate)
        backup="$TARGET.claude-restore-bak.$(date +%Y%m%d-%H%M%S)"
        cp "$TARGET" "$backup"
        echo "Backup: $backup"

        # Sed pattern: only on `alias ` lines, replace bare `claude` token.
        # The token is preceded by [' &] (single quote, space, or &) and
        # followed by ['  ;|&] or end-of-line. We capture both bounds.
        sed -i -E "/^[[:space:]]*alias[[:space:]]/ s/(['& ])claude(['[:space:];|&]|\$)/\\1cr wrap\\2/g" "$TARGET"

        echo
        echo "Diff:"
        diff -u "$backup" "$TARGET" || true
        echo
        echo "Done. Reload with:  source $TARGET"
        ;;

    revert)
        latest="$(ls -t "$TARGET".claude-restore-bak.* 2>/dev/null | head -1 || true)"
        if [ -z "$latest" ]; then
            echo "ERROR: no backup found matching $TARGET.claude-restore-bak.*" >&2
            exit 1
        fi
        cp "$latest" "$TARGET"
        echo "Reverted from: $latest"
        ;;
esac
