# Incident: 2026-05-26 — tmux server cleaned up by systemd, team lost

**Status:** mitigated. Investigation + safeguards landed same day.

## Summary

At 21:06:36 UTC (23:06:36 CEST) on 2026-05-26, the team's tmux server on socket
`-L orchestrator` was wiped out in a single second, killing all eight role
processes (`researcher`, `ux-designer`, `graphic-designer`, `implementer1`,
`implementer2`, `tester1`, `reviewer1`, `integrator`) and the orchestrator
itself. The `/is` bus server, the dashboard HTTP server, and `api-watchdog.sh`
all survived because they were started detached (`nohup ... &`) and lived in
their own scopes.

The team had been running for 4 h 22 min and was mid-`u16-verify-themes`.
All git commits, the ledger (`$TEAM_DIR/state.md`), and all assets on disk
were intact; only the in-memory role processes and the tmux server were lost.

## Root cause

`journalctl --since "23:05" --until "23:10"` shows seven `tmux-spawn-*.scope`
units logging "Consumed CPU time …" at exactly `23:06:36`:

```
May 26 23:06:36 systemd[252]: tmux-spawn-0b330b6e-… : Consumed 26m27s CPU over 4h22m wall, 812.9M peak
May 26 23:06:36 systemd[252]: tmux-spawn-eea1278e-… : Consumed 28m12s CPU over 4h22m wall, 774.9M peak
May 26 23:06:36 systemd[252]: tmux-spawn-b5cc4d4a-… : Consumed 53m51s CPU over 4h22m wall, 985.5M peak
May 26 23:06:36 systemd[252]: tmux-spawn-eb651198-… : Consumed 43m28s CPU over 4h22m wall, 935.6M peak
May 26 23:06:36 systemd[252]: tmux-spawn-ef7b756e-… : Consumed 23m53s CPU over 4h22m wall, 824.8M peak
May 26 23:06:36 systemd[252]: tmux-spawn-5ae971d2-… : Consumed 55m18s CPU over 4h22m wall, 1.2G peak
May 26 23:06:36 systemd[252]: tmux-spawn-8265a732-… : Consumed 26m38s CPU over 4h22m wall, 756.5M peak
```

`systemd[252]` is the user-session manager for `uid 1000` (LEADER of session
`c1`). The `tmux-spawn-*.scope` units are systemd transient scopes; each
`tmux new-window` creates one. All seven scopes had the same wall-clock age
(4 h 22 min), they were all created together when the team was launched, and
they all died together when the user manager decided to clean them up.

`earlyoom` did not do it: the memory log shows available memory went *up*
~6.8 GiB at the same moment (58.8% → 93.0%), which is the freed working sets
of the dying processes. `KillUserProcesses` is at its default (`no`) and
`Linger=yes` is set for the user, so a normal session-end should not have
triggered this.

The likeliest trigger in this WSL2 environment is one of:

1. A WSL2 lightweight suspend/resume (Windows host idle) that left systemd
   thinking the transient scopes had timed out.
2. A `systemctl --user daemon-reload` issued by some other tool that decided
   to clean up scopes considered orphaned.
3. A manual `systemctl --user stop tmux-spawn-*.scope` issued by stale tooling.

The fix below makes the precise trigger no longer matter.

## Why nothing caught it

`bin/api-watchdog.sh` watches for the specific "API/network error" pane
patterns. When a pane simply ceases to exist (because its tmux server died),
the watchdog has nothing to classify; it kept reporting `active` for every
role's pre-crash health JSON.

Outside observers (`bin/team-status.sh`, the dashboard server) read the
ledger and health JSON, both of which kept saying "OK" because no one was
updating them. The first sign of the crash, from the operator side, was a
`tmux capture-pane` failing with `no server running on /tmp/tmux-1000/orchestrator`.

## Mitigations (landed same day)

1. **`bin/tmux-watchdog.sh`** (new). Polls
   `tmux -L $TEAM_TMUX has-session -t $TEAM_SESSION` every 15 s. If the
   session is gone *and* `$TEAM_DIR/active` still has live entries, it:
   - flips `$TEAM_DIR/health/tmux.json` to `state=crashed`,
   - appends an event to `$TEAM_DIR/audit/tmux.log`,
   - drops `$TEAM_DIR/CRASH-DETECTED.md` with the run id and recovery command,
   - sends an `ntfy` push if `NTFY_URL` is set.

   Also takes a forensic snapshot of every window every 60 s into
   `$TEAM_DIR/snapshots/<window>.txt`. After a crash, the most recent
   snapshot is the closest thing to a post-mortem of pane state.

   The watchdog **does not auto-restart the team.** Recovery still goes
   through the operator. Auto-restart is dangerous if the cause is still
   present (e.g. the suspend/resume scenario could repeat immediately).

2. **`setsid tmux new-session …` in `bin/start-orchestrator.sh`.** Putting
   the tmux server in a new session/process group with no controlling
   terminal detaches it from this shell's user-session scope. A
   session-cleanup event targeting the spawning shell can no longer sweep
   the tmux server with it.

   Fall-back: if `setsid` is unavailable, the original invocation is used.

3. **Lifecycle wiring.** The tmux watchdog joins the api-watchdog and
   dashboard pattern:
   - `bin/lib/team-spawn.sh::start_tmux_watchdog` (idempotent),
   - started from `bin/launch-team.sh` after the api-watchdog,
   - stopped from `bin/stop-team.sh` and `bin/cleanup.sh` (same pattern as
     api-watchdog).
   Disable with `TMUX_WATCHDOG_DISABLED=1` if needed.

## Recovery flow (proven on 2026-05-26)

Same run-id resume worked:

```bash
export TEAM_RUN_ID=r1779813443481305   # same id => same TEAM_DIR/state.md
rm -f /tmp/tmux-1000/orchestrator      # remove the dead socket file
mv $TEAM_DIR/active $TEAM_DIR/active.crashed-$(date +%s)
touch $TEAM_DIR/active
# append a "RECOVERY" line to $TEAM_DIR/state.md decision-log
bin/start-orchestrator.sh goals/b11-redesign.md
# then nudge the newly-spawned orchestrator with a recovery prompt explaining
# it is a resume, naming the last in-flight unit, and listing the surviving
# roles to relaunch via bin/launch-team.sh
```

Per-role context is lost (each role started fresh with no prior conversation
history) but the ledger lets the orchestrator brief each one on its current
unit in a few hundred tokens.

## Open follow-ups

- **Watchdog cannot detect the variant where a role process dies but tmux
  stays alive.** Out of scope for this incident; track separately as a u25
  candidate (queued-input-with-no-active-process pattern).
- **Decide whether auto-restart should be added** behind an explicit
  `--auto-recover` flag. Today's choice is conservative (operator gates the
  decision). A B2-style autonomous run might want the opposite default.
- **Snapshot rotation.** The snapshot dir grows unbounded over a long run.
  Cap at the last N snapshots or rotate hourly.
