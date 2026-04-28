# ClaudeRestore (`cr`)

Restore Claude Code terminal sessions across PC restarts.

Claude Code already persists every conversation as a `.jsonl` in `~/.claude/projects/…`,
so the *content* survives reboots. What's lost is the *mapping* of "which session
was open in which terminal." `cr` tracks that mapping and reopens those terminals
on demand after a restart.

No tmux required. Per-session heartbeat written by a thin wrapper around the
`claude` binary; restoration filters previous-boot entries by comparing their
last heartbeat to the previous boot's last journal entry.

---

## Install

```bash
./install.sh
```

This:
- Symlinks `bin/cr` → `~/.local/bin/cr`
- Creates `~/.claude/active-sessions/` registry directory
- Merges SessionStart and SessionEnd hook entries into `~/.claude/settings.json`
- Idempotent: re-running is safe.

Then route your `claude` aliases through the wrapper. The optional helper
edits the existing `alias` lines in `~/.bash_aliases` in place (with backup):

```bash
./scripts/migrate-aliases.sh
source ~/.bash_aliases
```

Or do it manually — replace `claude` with `cr wrap` inside `alias` values:

```bash
alias c='claude'                                   →  alias c='cr wrap'
alias ika='cd /path/to/Ikariam && claude'          →  alias ika='cd /path/to/Ikariam && cr wrap'
```

After that, every interactive Claude Code session you open is tracked.

---

## Usage

| Command | Action |
|---|---|
| `cr` | Auto-restore previous-boot sessions. Skips any `session_id` already alive in this boot. |
| `cr restore` | Interactive picker: lists candidates with first-prompt previews, you choose. |
| `cr restore --all` | Same as `cr` — no prompt. |
| `cr status` | Show registry: live this boot, restorable from previous, stale. |
| `cr clean` | Garbage-collect stale and dead-this-boot entries. |
| `cr wrap …` | Internal — invoked by your aliases. Wraps `claude` with heartbeat tracking. |
| `cr help` | Full help. |

---

## How it works

### Tracking

When `cr wrap` invokes `claude`:
1. Wrapper exports `CR_HANDOFF` (path to a temp file in `$XDG_RUNTIME_DIR`).
2. Wrapper spawns a background heartbeat loop and `exec`s the real `claude`.
3. Claude's `SessionStart` hook fires. The hook reads the session_id from stdin,
   writes `~/.claude/active-sessions/<sid>/info.json` (with `pid`, `pid_starttime`,
   `boot_id`, `cwd`, `terminal`), publishes the session_id to `$CR_HANDOFF`,
   and creates an initial `heartbeat` file.
4. Heartbeat loop reads the session_id from the handoff file and `touch`es
   the heartbeat file every 5s. The loop's lifetime is gated by
   `cr_pid_alive(wrapper_pid, starttime)` — defeats PID reuse.

When the user `/exit`s cleanly, `SessionEnd` removes the registry entry. If
the terminal window is closed (SIGHUP) or the system shuts down, `SessionEnd`
does *not* fire — but the heartbeat stops, which is the actual signal we use.

### Restore decision

For each registry entry from a *previous* boot:

```
last_journal_entry = journalctl --list-boots → end-of-boot for this entry's boot_id
gap = | last_journal_entry − heartbeat_mtime |
restore if gap ≤ 30 seconds
```

Why this works: the heartbeat updates every 5s while the wrapper is alive. If
the system died with the session still open, the last heartbeat is within ~5s
of the system's actual death, which is essentially what
`journalctl --list-boots` records as the boot's "last entry." A session closed
hours before shutdown has a heartbeat hours before the boot's last entry → big
gap → not restored.

For each restore candidate, `cr` (or `cr restore`) launches a new terminal
window in the recorded `cwd` running `claude --resume <session_id>`. The
session's `.jsonl` transcript is verified to still exist before launching.

### Edge cases

- **Already-live session:** `cr` skips any candidate whose `session_id` is
  already alive in the current boot (so re-running `cr` doesn't open dupes).
- **Missing transcript:** `~/.claude/projects/<encoded-cwd>/<sid>.jsonl` deleted
  → entry is classified `missing-jsonl` and `cr clean` removes it.
- **Terminal hint stale:** detected terminal at session start is stored as a
  hint. If that terminal isn't installed at restore time, falls back through
  a list. Override globally with `CR_TERMINAL=kitty cr`.

---

## Configuration

Environment variables:

| Var | Default | Purpose |
|---|---|---|
| `CR_REGISTRY` | `~/.claude/active-sessions` | Where session info lives |
| `CR_HEARTBEAT_INTERVAL` | `5` | Heartbeat update interval, seconds |
| `CR_RESTORE_THRESHOLD_SEC` | `30` | Max gap from boot end to count as "alive at shutdown" |
| `CR_TERMINAL` | (auto-detected) | Override terminal launcher: `kitty`, `gnome-terminal`, `alacritty`, etc. |
| `CR_LOG_TAG` | `claude-restore` | Tag for journal entries (`journalctl -t claude-restore`) |

---

## Uninstall

```bash
./uninstall.sh
```

Removes the symlink and hook entries from `settings.json`, optionally removes
the registry. Does NOT touch `~/.bash_aliases` — revert via:

```bash
./scripts/migrate-aliases.sh --revert
```

---

## Troubleshooting

```bash
journalctl -t claude-restore   # hook log output
cr status                      # what's tracked
cr clean                       # remove stale
```

Common issues — see `AGENT.md` for AI-assisted debugging context.

---

## Requirements

- Linux with systemd (uses `/proc/sys/kernel/random/boot_id` and `journalctl --list-boots`)
- `jq`, `journalctl`, `bash`
- One of: kitty, gnome-terminal, alacritty, wezterm, konsole, foot, ghostty, terminator, tilix, cosmic-term, or xterm
