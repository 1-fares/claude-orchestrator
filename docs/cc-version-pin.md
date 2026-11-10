# Claude Code version: auto-update block and minimum version

A long-running team should not change Claude Code version mid-run. The
mechanism is not a pin: it is an auto-update block (`DISABLE_AUTOUPDATER`)
plus the CLI's own `minimumVersion` setting. Nothing in `bin/` checks which
version a role runs, so a manual `claude install` or `claude update` still
changes it. This doc records why, how the block works, and the upgrade
procedure (canary-green first).

## Why block auto-update

Claude Code's **native** install auto-updates in the background of any running
session and silently repoints `~/.local/bin/claude` to the newest version. In
one live run that pushed 2.1.170 mid-run, which changed the `/context` output
format and **blinded the compaction watchdog's context probe**
(`parse_context_pct` in `bin/lib/compaction-detect.sh`) for hours before it was
caught. A long-running team must not have its tooling shift underneath it
mid-run; several supervisors parse the live pane (the compaction probe, the
api-watchdog busy/stall detectors), and that surface is not a stable API.
Upgrades become a deliberate step gated on a working-probe canary.

## The mechanism (two layers)

1. **Host-wide (authoritative):** `~/.claude/settings.json`
   - `env.DISABLE_AUTOUPDATER = "1"` stops the background auto-updater for every
     session under that user. `claude install <version>` still works, so a
     deliberate upgrade is unaffected.
   - `minimumVersion = "<verified>"` is a downgrade floor; a stray
     `claude update` will not drop below the version the team was verified on.
2. **Team-process belt:** `bin/team-env.sh` exports `DISABLE_AUTOUPDATER=1`, so
   every team-spawned session inherits the auto-update block even if the host
   setting is ever reverted. `${DISABLE_AUTOUPDATER:-1}` lets an operator
   override per invocation.

`"autoUpdates": false` in `~/.claude.json` is a legacy/undocumented key and is
NOT the lever that stops the native background updater; `DISABLE_AUTOUPDATER`
is.

Record the verified version somewhere durable on the host (the settings
`minimumVersion` doubles as that record). Nothing compares a running session's
version with it; check `claude --version` after any install.

## Deliberate-upgrade procedure (canary-green first)

Do NOT just run `claude install latest`. The probe parser
(`parse_context_pct`) and the watchdog canaries key on the exact `/context` and
pane render formats, which change between versions. Upgrade only after proving
the new version still parses:

1. **Install the new version WITHOUT switching the team to it yet.** Native
   install drops it under `~/.local/share/claude/versions/<new>` and repoints
   the symlink, so do this in a scratch shell and be ready to repoint back:
   - Note the current target: `readlink -f ~/.local/bin/claude`.
   - `claude install <new-version>` (or `stable`).
2. **Canary the probe against the new version.** In a scratch Claude Code
   session on the new version, run `/context`, capture the pane
   (`tmux capture-pane -p -S -60`), source `bin/lib/compaction-detect.sh`, and
   pipe the capture through `parse_context_pct`; it must print a non-empty
   percent. The compaction watchdog also runs a start-time canary and logs
   `canary: probe healthy at startup (read NN%)` vs `CANARY-FAIL`; the
   api-watchdog logs a canary verdict on pane readability and recognised
   Claude Code chrome.
3. **If the canary is GREEN:** update `minimumVersion` and the host's version
   record, restart the watchdogs (`kill -TERM` the recorded pids, freeing the
   lock as the next section describes; `bin/tmux-watchdog.sh` re-ensures them
   within its scan interval, or re-run the launcher), and confirm the new start
   logs show the canaries green.
4. **If the canary is RED:** the new version changed the `/context` format.
   Repoint the symlink back to the verified version
   (`ln -sfn ~/.local/share/claude/versions/<verified> ~/.local/bin/claude`),
   then update `parse_context_pct` (and `bin/tests/compaction-probe-test.sh`
   with a captured sample of the new format) BEFORE retrying the upgrade.

## Restarting the compaction watchdog cleanly

The daemon's `sleep $INTERVAL` is an external child that inherits the flock fd.
The daemon traps TERM/INT and reaps that child on exit, but bash runs the trap
only after the foreground `sleep` returns, so `kill -TERM <pid>` alone holds
`$TEAM_DIR/compaction-watchdog.lock` for up to INTERVAL seconds
(`COMPACT_CHECK_INTERVAL`, default 180). To free it at once, also end that
child: `kill -TERM <pid>; pkill -TERM -P <pid> sleep`. A bare `kill -9` (no
trap) leaves an orphaned `sleep` holding the lock for the same time; `fuser`
the lock file and kill the holder before relaunching if that happens.

## Version skew inside a team

Even with the auto-update block, a team restarted role-by-role can end up with
sessions on different Claude Code versions (an orchestrator started before the
upgrade, workers after). Pane-parsing tools key on the rendered format of whichever
version a pane runs, so prefer upgrading the whole team in one restart over a
rolling mix.
