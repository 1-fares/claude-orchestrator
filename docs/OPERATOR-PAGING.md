# Operator paging: what reaches the phone, and what does not

The phone is for what only a human can do, or must know within minutes. Everything the
engine can fix itself goes to the engine (the orchestrator over the bus, an ensure, a
watchdog), and everything else goes into one silent daily digest. Written 2026-09-07 after
a morning in which the operator received 38 pushes, 26 of them at priority urgent for a
condition the engine could have fixed in one command.

## What happened on 2026-09-07 (the case this policy is built from)

| Time | Pushes | What it was | Class it should have been |
|---|---|---|---|
| 07:24 | 2 | a watchdog restarted by tmux-watchdog, then its FREEZE banner (the band was self-imposed) | info |
| 07:31 | 11 | four lanes dropped and restored by the reconciler after a planned relaunch | info, and muted: the operator had just rebooted the box |
| 07:35-11:50 | 22, urgent | five delivery-monitor loops not restarted after the reboot; the staleness checker paged once per watch per hour | none to the phone: an ensure restarts a watch; the team is told over the bus; action only after that fails twice |
| 07:51 | 1 | compaction canary alarm raised while the orchestrator was busy | info |
| 11:00, 11:10 | 2 | usage-band restore refused at the reset instant, then applied but not live | info (designed refusal), action (a human had to restart it) |
| 11:53 | 1, urgent | a watch exited non-zero on a finding and the runner paged it as a death | none: a finding exit is not a death |

Three defects, not one: no severity model (ten daemon copies of `curl -d text` at default
priority, the watch library at urgent); no maintenance mute; and self-healable conditions
escalated to a human instead of to the engine. No audit trail existed for most senders, so
the history was ntfy's 12-hour cache.

## Classes (bin/lib/notify.sh)

| Class | ntfy priority and phone behaviour | Rule | Rate |
|---|---|---|---|
| `page` | 5: long vibration, sound, pop-over | a human must act now: production impact, data exposure, the team dead beyond self-heal, a delivery failure, an outbound message to a recipient outside the allow-list | a repeat for the same subject goes out again once 30 min have passed, for as long as the sender keeps reporting it; no "resolved" push is sent (nothing calls `notify_resolved`); ignores hours; during a mute it still goes, prefixed `[maintenance]` |
| `action` | 4: vibration, sound, pop-over | a human must act today: only the operator holds the key, credential or decision | one push per subject per 6 h; queued outside Mon-Fri 07:00-19:00 Zurich and flushed by the next in-hours `--flush` or `--digest` (the 08:00 cron below); dropped during a mute (logged) |
| `info` | 2: silent, hidden until the drawer is pulled | everything else | never pushed on its own; one digest per working day at 08:00 (the cron below); the digest file keeps at most `NOTIFY_DIGEST_MAX_LINES` lines |

Deny by default. The daemons' old one-argument `notify "<emoji> text"` now goes through
`notify_legacy`: a leading red circle is `action`, everything else is `info`. Nothing
pages unless the call site says `page`. The CLI `bin/notify-operator.sh TITLE MESSAGE
[page|action|info]` maps the old priorities down: `urgent` and `high` are `action`.

Every decision is one line in `$TEAM_DIR/reports/operator-pings.log`:
`<utc> | <DECISION> <class> [<prio>] <subject> :: <body>`, where DECISION is SENT,
LOG-ONLY (no `NTFY_URL`, or the push failed), DEDUPE, MUTED, QUEUED, DIGEST, DEMOTED or
BAD-CLASS; the flush and digest steps log FLUSHED, FLUSH-FAILED, DIGEST-SENT,
DIGEST-FAILED and DIGEST-EMPTY. A failed push adds a PUSH-FAIL line with curl's exit
code and the HTTP status (curl runs with `-f`, so an HTTP 4xx or 5xx from ntfy is a
failure, not a delivery). DIGEST-TRIMMED records info lines dropped at the digest cap, and
LOCK-SKIPPED a queue or digest write made without its lock. A ping exists when the log says
SENT; QUEUED and DIGEST mean the policy accepted it and will deliver it on its own schedule.

## Maintenance mute

Before planned work an operator runs `bin/notify-operator.sh --mute '2026-09-07 08:30'`
(or writes the instant to `$TEAM_DIR/health/maintenance-until`). `--mute` takes an epoch or
any `date -d` string, resolves it once and stores the epoch; a value that does not parse, or
is not in the future, is refused with exit 2 and nothing is written. Actions are dropped and
logged MUTED (not queued, not delivered later); info still goes to the digest, which never
pushes on its own; pages still go, prefixed. `--unmute` ends it early. A relaunch or reboot
without a mute is the 07:31 row above.

## Configuration (environment, read by bin/lib/notify.sh)

| Variable | Default | Effect |
|---|---|---|
| `NTFY_URL` | unset | ntfy topic URL; unset = log only, every decision still logged |
| `NOTIFY_ACTION_SOURCES` | unset (every sender) | space-separated `NOTIFY_SOURCE` names whose `action` pushes; any other sender's action is DEMOTED to the digest; `""` or `*` = every sender |
| `NOTIFY_SOURCE` | unset | the calling daemon's name; checked against the list above, subject prefix for `notify_legacy` |
| `NOTIFY_HOURS`, `NOTIFY_DAYS`, `NOTIFY_TZ` | `0700-1900`, `1-5`, `Europe/Zurich` | the push window for `action`; outside it actions are queued |
| `NOTIFY_ACTION_COOLDOWN_SEC` | `21600` | one `action` push per subject per this many seconds |
| `NOTIFY_PAGE_REPEAT_SEC` | `1800` | a repeated `page` for the same subject goes out again after this many seconds |
| `NOTIFY_DIGEST_MAX_LINES` | `1000` | cap on the info digest: an append that takes it past the cap drops the oldest lines down to 90% of it and logs DIGEST-TRIMMED with the count; `0` = no cap |
| `NOTIFY_MUTE_FILE` | `$TEAM_DIR/health/maintenance-until` | the maintenance mute (see above) |
| `NOTIFY_LOG` | `$TEAM_DIR/reports/operator-pings.log` | the decision log |
| `NOTIFY_STATE_DIR` | `$TEAM_DIR/health/notify` | dedupe stamps, the out-of-hours queue, the digest |
| `NOTIFY_SINK` | unset | tests: append `prio\|title\|body` to this file instead of pushing; with it set, an unset `NOTIFY_LOG` and `NOTIFY_STATE_DIR` default to `${NOTIFY_SINK}.log` and `${NOTIFY_SINK}.state` |
| `NOTIFY_NOW` | `date +%s` | tests: the current time as an epoch |

## Cron

```
0 8 * * 1-5   cd <repo> && bin/notify-operator.sh --digest     # one silent digest, flush queued actions
```

## Who acts: the test for each call site

- Can the engine fix it in one command (restart a watch, respawn a lane, compact a pane,
  reap a window)? Then it is not a notification at all until the fix has failed twice; the
  first failure goes to the orchestrator over the bus, the second is `action`.
- Does it change what the operator would do in the next hour (production down, a delivery
  file quarantined, the team silent while the product owner waits, a message about to go to
  someone outside the allow-list)? `page`.
- Does it need the operator's hands today but not now (rotate a credential only he holds,
  re-subscribe a topic, a GO on a production write, /login after an account switch)? `action`.
- Is it a fact the operator likes to know but would never act on (a lane respawned, a band
  changed, a canary deferred, a role added)? `info`.

## Declarations to make (the migration list, 2026-09-07 inventory of 64 call sites)

page: tmux session gone while roles are active (tmux-watchdog); orchestrator wedged past
the reconciler's own retire+respawn (api-watchdog, the `-esc` step); an outbound message
addressed outside the allow-list (new guard); production unreachable or 5xx on two
consecutive probes (new probe); a quarantine or error file from the delivery monitors (which
today only write to their logs); a MULTI-DAY usage wall, where the role's own refusal
record names a reset further out than USAGE_WALL_PAGE_SEC (api-watchdog). The last one is
a page and not an action because it does not clear on its own: the team is stopped for
days until the operator switches account. An ordinary session limit stays info, as before.

action: a role blocked on an interactive prompt after the escalation ladder (api-watchdog);
all roles rate-limited and a /login needed (account-rotation); host RAM or disk in FREEZE
(the resource watchdogs); the state backup not pushed for 24 h (new check; the job is not
even in the crontab today); a TLS certificate under 14 days (new check); a Teams surface
missing from the poller's state (teams-poller); the Monday resume with problems
(resume.sh); a watch still stale after two ensure restarts (staleness checker, digest of
all stale watches in one push, cooldown per run not per watch); usage-band restore applied
but not live.

info: everything else, including every lane respawn, watchdog restart, band transition,
canary, usage-band refusal, role add or retire, a status-hook post to an outside channel,
and a production write once executed (the operator wants to see those in the digest).

## Coverage that did not exist on 2026-09-07 and must be built (engine work)

1. Production availability probe from the box, every 5 minutes, `page` on two consecutive
   failures. The laptop monitor probes dev and preprod only.
2. dev and preprod down in working hours: `action`, with the team's own declaration in
   `health/env-availability.json` quoted.
3. TLS expiry, daily: `action` under 14 days, `page` under 3.
4. A state backup every two hours in the crontab (this repository contains no
   backup script), and `action` when the backup repo has not been pushed for 24 hours (it had
   not been pushed for 19 days).
5. OAuth death: `page` when the token is past `expiresAt` and no session has answered in
   15 minutes.
6. Delivery-monitor findings routed as `page` (quarantine, error file) or
   `action` (redelivery, row-count change), with the finding text; the watch runner must not
   page a finding exit as a death.
7. A message from the product owner or the vendor unanswered for 60 minutes in working hours:
   `action` (the acknowledge-with-time rule is the team's; the page is the backstop).
8. The status hook's external posts and every executed production write: `info`.

## Maintenance mute/unmute procedure

Before a planned restart or maintenance window, mute action notifications so they do
not fire during the downtime. A muted action is dropped (logged MUTED), not queued; a
condition that still holds after the window is pushed by its daemon's next check:

```bash
bin/notify-operator.sh --mute "$(date -d '+2 hours' +%s)"   # mute for 2 hours
bin/notify-operator.sh --mute "2026-09-07T16:00:00+02:00"    # mute until a specific time
```

Pages still go through (prefixed `[maintenance]`). After the window:

```bash
bin/notify-operator.sh --unmute
bin/notify-operator.sh --flush    # push actions queued OUT OF HOURS (a mute queues nothing)
```

The daily `--digest` cron above (08:00 Mon-Fri) flushes the out-of-hours queue on workday mornings.
