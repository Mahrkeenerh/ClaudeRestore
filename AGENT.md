# ClaudeRestore — Agent Context

## Overview

CLI tool that restores Claude Code interactive sessions across PC restarts.
Two halves: a thin Bash wrapper around `claude` that emits per-session
heartbeats, and a `cr` command that classifies registry entries by comparing
their last heartbeat to the previous boot's last journal entry.

## Quick Commands

```bash
cr                # auto-restore previous-boot sessions (skip already-live)
cr restore        # interactive picker
cr status         # show registry classification
cr clean          # GC stale / dead-this-boot / missing-jsonl entries
journalctl -t claude-restore   # hook diagnostic logs
```

## Files

- `bin/cr` — main entry, dispatches subcommands
- `lib/common.sh` — shared helpers (boot_id, terminal detection, journalctl parsing, user-login epoch via loginctl, heartbeat ops)
- `hooks/session-start.sh` — Claude SessionStart hook: writes registry entry, publishes session_id to `$CR_HANDOFF`
- `hooks/session-end.sh` — Claude SessionEnd hook: removes registry entry on clean exit
- `scripts/migrate-aliases.sh` — optional in-place rewrite of `claude`→`cr wrap` in user's `~/.bash_aliases`
- `install.sh` / `uninstall.sh` — symlink + settings.json hook merge (idempotent)

## Key data locations

- **Registry**: `~/.claude/active-sessions/<session-id>/` — contains `info.json` (static metadata) + `heartbeat` (touched file, mtime is the signal)
- **Handoff**: `$XDG_RUNTIME_DIR/claude-restore/handoff.XXXXXX` — temp file the wrapper exports as `$CR_HANDOFF`; SessionStart writes session_id into it
- **Hooks**: registered in `~/.claude/settings.json` under `.hooks.SessionStart` and `.hooks.SessionEnd`
- **Transcripts** (read-only, owned by Claude Code): `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`

## How restoration decides

`cr_classify` has two branches based on whether the registry entry was created
in the current kernel boot.

### Same-boot entries (recovers user-space restarts)

Within a boot, PID/starttime liveness is meaningful, so we use it directly:

1. PID alive (and starttime matches) → `live`.
2. PID dead, no transcript → `missing-jsonl`.
3. PID dead, heartbeat ≥ user_login_epoch → `dead-this-boot`. The wrapper
   died inside the current user-login session — user closed the terminal.
4. PID dead, heartbeat < user_login_epoch → `crash-restorable`. The wrapper
   died crossing a user-login boundary — X/Wayland crash, display-manager
   restart, logout/login — every previous-login terminal is dead.

`user_login_epoch` is the max `Timestamp` among the current user's
non-empty-`Seat` logind sessions (filters out remote-desktop pseudo-sessions
like chrome-remote-desktop). Empty if loginctl is unavailable, in which case
we fall back to "any same-boot PID-dead → crash-restorable" (potential
false-positive restores, but no lost work).

### Previous-boot entries (recovers full reboots)

1. Look up `info.boot_id`'s last journal entry: `journalctl --list-boots` → last column.
2. `gap = | boot_last_entry_epoch − heartbeat_mtime |`
3. `crash-restorable` iff `gap ≤ $CR_RESTORE_THRESHOLD_SEC` (default 30s); else `stale`.
4. No anchor (boot has aged out of `journalctl --list-boots`, or heartbeat
   missing) → `stale`. An entry that old must never resurrect — this was the
   cause of the "restored way too many sessions" bug, where every accumulated
   entry from a rotated-out boot lit up as a restore candidate.

This works because: if the system died with the wrapper still running, its
last heartbeat is within ~5s of journalctl's last recorded moment. A session
closed long before shutdown has a heartbeat far before the boot's end.

### `crash-restorable` is per-entry; the target boot decides what actually restores

`cr_classify` only says whether an entry was alive when *its own* boot/login
died. It does **not** decide restoration. `cr_target_boot` then picks the
single boot we restore from: the **most recent boot (by `journalctl` index)
that has any `crash-restorable` entry**. `cr_final_class` maps each entry to
its final verdict — `crash-restorable` on the target boot → `restore`; on any
older boot → `stale` (superseded).

Why: registry entries accumulate (preserve-by-default SessionEnd, manual GC),
and a long-lived boot can hold a *month* of dead entries. Without this scoping,
every reboot re-offered survivors from every past boot, ballooning the restore
list. The target-boot rule is also a **walk-back**: if the immediately previous
boot crashed before any session was alive (no `crash-restorable` entries), the
rank search naturally falls through to the boot before it, and so on. The
current boot has rank 0 (highest), so a user-space crash that didn't reboot
takes precedence over any earlier boot.

### The SessionEnd hook is preserve-by-default

Only `clear|resume|prompt_input_exit|bypass_permissions_disabled` cause the
hook to remove the registry entry. Every other `exit_reason` (including
empty/unset, which is what fires on session-manager crash) preserves the
entry — `cr_classify` then decides restorability. This matters because Claude
Code fires SessionEnd with `exit_reason=""` on display-server crashes; a
strict deny-list previously wiped the entries before they could be recovered.

## Troubleshooting

### "Nothing to restore" but I had sessions open

Check classification:
```bash
cr status
```

Look in the **Stale** section. Common causes:
- Session was closed cleanly (`/exit`) before reboot — SessionEnd removed the entry. Working as intended.
- Heartbeat was much older than `journalctl --list-boots` end timestamp:
  - Wrapper was killed before reboot (window closed)
  - System didn't write to journal between session activity and shutdown — rare, but check `journalctl --list-boots` output to verify the boot's last_entry timestamp is reasonable.
- The registry entry's `boot_id` was already current (entry was created in the *current* boot, which means the session was started this boot, not before).

### Hook not firing on session start

```bash
journalctl -t claude-restore --since "10 minutes ago"
jq '.hooks.SessionStart' ~/.claude/settings.json
```

The settings.json `.hooks.SessionStart` array should contain an entry whose
inner `.hooks[].command` equals the absolute path to `hooks/session-start.sh`
in this repo. If absent, re-run `./install.sh`.

### Wrapper not invoked (`info.json` shows wrong PID, missing `pid_starttime`)

The session was started by raw `claude`, not via `cr wrap`. Check your shell
aliases:
```bash
grep claude ~/.bash_aliases
```
Should show `cr wrap` instead of bare `claude`. Run `./scripts/migrate-aliases.sh`
or edit by hand.

### Terminal won't spawn at restore

Override the launcher:
```bash
CR_TERMINAL=kitty cr
```

Or check what's installed:
```bash
for t in kitty alacritty wezterm konsole gnome-terminal foot xterm ghostty cosmic-term terminator tilix; do
    command -v $t >/dev/null 2>&1 && echo "✓ $t"
done
```

### Stale handoff files in `$XDG_RUNTIME_DIR/claude-restore/`

The heartbeat loop is supposed to `rm -f "$CR_HANDOFF"` on exit. If the wrapper
was SIGKILL'd (very rare), the handoff might persist. Safe to delete manually:
```bash
rm -f /run/user/$(id -u)/claude-restore/handoff.*
```
`$XDG_RUNTIME_DIR` is also tmpfs and cleared at logout/reboot, so these never
accumulate across reboots.

## Hook semantics relied upon

- `SessionStart` fires on both fresh `claude` invocations AND `claude --resume`
  (verified via Anthropic docs: `source` field = `"startup" | "resume" | "clear" | "compact"`).
- Hook receives stdin JSON with `session_id`, `cwd`, `source`, etc.
- Hook is **blocking** — its execution time delays Claude startup. Keep fast (<100ms typical).
- Hook inherits env vars from the parent `claude` process (which inherited from `cr wrap`).
  This is how `$CR_HANDOFF` propagates. **If env stripping is ever introduced**, the
  handoff design breaks; switch to a deterministic per-PPID handoff filename.
- `SessionEnd` does NOT reliably fire on SIGHUP (window close) or SIGTERM (shutdown).
  This is the entire reason for the heartbeat approach.

## Things to verify if behavior changes after Claude Code update

- `SessionStart` still fires on `--resume`
- Hook stdin still contains `session_id` and `cwd`
- Env vars still propagate through to hooks
- `claude --resume <id>` still works for sessions stored in `~/.claude/projects/…`
