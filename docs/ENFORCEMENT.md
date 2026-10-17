# ENFORCEMENT: which behaviour is held by which mechanism

A rule that lives only in a memory file or a standing-rules card is read, agreed with, and
still not applied under pressure. Every behaviour the team is expected to keep has one row
here naming its mechanism. A behaviour whose only mechanism is a rule is marked
**UNENFORCED** with an owner; the observer reports those rows.

Three layers, in order of strength:

1. **Gate** (a hook or a script exit): the wrong action cannot happen. PreToolUse hooks on
   the tool that would do it (exit 2 = blocked, the reason is handed to the model), git
   hooks, and scripts that refuse. Each gate has a regression test that replays the
   incident that created it.
2. **Check** (a cron or a daemon): the wrong state is found and reported within a bounded
   time (digest, action or page per `docs/OPERATOR-PAGING.md`).
3. **Rule** (card, memory): explains WHY the gate or check exists. Never the only mechanism
   for something that has already gone wrong once.

| Behaviour | Layer | Mechanism | Test | On violation |
|---|---|---|---|---|
| A credential, gate URL or value leaves the box only after a live measurement in the same turn | Gate | `bin/hooks/gate-outbound-reply.sh` check 1: every gate value and shared-login password in the body must be in `$TEAM_DIR/health/env-logins.json` (written by the deployment's login probe) and under 15 min old | `bin/tests/gate-outbound-reply.test.sh` 1-3 | send blocked |
| The right connector tool for the id (chat reply tools that never work, channel ids on chat tools) | Gate | same hook, check 0a | test 11 | send refused, right tool named |
| Outbound only to the operator's recipient list | Gate | same hook, check 0b. The list is `$OUTBOUND_ALLOWLIST`, else `$DEPLOY_DIR/outbound-allowlist.txt` inside the repo (`DEPLOY_DIR` names the deployment's own directory, default `local/`), else `config/outbound-allowlist.txt`; a missing file blocks everything. `gate-outbound.conf` (check 1 patterns) resolves the same way | tests 10, 12, 13 | send blocked |
| Never ask the requester to re-check a step the team can test; no "will follow up" without a clock time | Gate | same hook, check 2 | tests 4-6 | send blocked |
| One reply per request, as one message | Gate | same hook, check 3, on the last SUCCESSFUL send recorded by the PostToolUse hook `bin/hooks/record-outbound-send.sh` (a failed attempt is not a message) | test 7 | send blocked |
| A message longer than a status line has a draft pass by the stronger model | Gate | `bin/hooks/gate-outbound-draft.sh` | UNENFORCED test; owner: the deployment | send blocked |
| A push the phone did not get is never reported as delivered | Gate | `bin/notify-operator.sh` exits 3 and says NOT DELIVERED on a demoted action | `bin/tests/notify-operator-cli.test.sh` | the calling command fails |
| Phone pushes: page = act now, action = today, all else digest; audible actions only from listed senders | Gate | `bin/lib/notify.sh` classes and `NOTIFY_ACTION_SOURCES` | `bin/tests/notify.test.sh` | demoted to the digest, logged |
| A "wedged" page needs the session transcript to agree | Gate | `bin/api-watchdog.sh` transcript veto (`bin/lib/watchdog-detect.sh`) | `bin/tests/watchdog-detect-test.sh`, `watchdog-stuck-integration-test.sh` | no nudge, no page, STUCK-VETO logged |
| Daemons run the code on disk | Gate | `bin/lib/self-reload.sh` | `bin/tests/daemons-self-reload.test.sh` | re-exec |
| No private data in a push | Gate | `bin/privacy-scan.sh` (pre-push) | in-hook | push refused |
| Whole-file reads over 200 lines in the engine tree | Gate | `bin/hooks/gate-read-size.sh` | none (UNENFORCED test) | read refused |
| No `rm`, `unlink`, `xargs rm` or `find -delete` with a wildcard or a variable in the path | Gate | `bin/hooks/gate-rm-glob-var.sh` (PreToolUse Bash), rule in `bin/lib/gate_rm_glob_var.py`: the path must be literal, through wrappers, `bash -c`, `eval`, `$(...)`, a heredoc a shell reads, and inline interpreter code. Known gaps: a script written then run, `eval` of an indirection the guard cannot resolve, code read from a file | `bin/tests/gate-rm-glob-var.test.sh` (36 rows, all red without the guard) | command refused, the message names the move-aside alternative |
| Rules with only a reminder (routing to the stronger model, observer cadence, units in the state table) | Rule + Check | `bin/hooks/standing-rules.sh` deviations; observer audits | none | **UNENFORCED**; owner: orchestrator |

## A check reads a machine-written field, never model prose

A check that greps a literal English phrase out of something the model wrote scores the
wording, not the behaviour. The model then writes to satisfy the grep, which is the
opposite of a control: the check passes on a wrong decision phrased correctly and fails on
a right decision phrased differently, and the only way to keep it green is to make the
model repeat a fixed string it cannot see the checker for.

So: a check reads a field with one allowed shape, written by code, at a known place. A
status column set by a ledger-writing helper, an exit status, a state file, a JSON key, a
commit trailer. If the behaviour genuinely lives in prose, the gate goes at the point of
action instead (a PreToolUse hook that refuses) and the prose is left alone.

Measured, 2026-10-11: a relay check decided whether an alarm had been passed on to the
people who own it by searching the orchestrator's log line for `not relayed:`. The
orchestrator declined a recurring alarm correctly and wrote "Not relayed again: nothing new
for <the owning team> or the vendor". Running the check against the log before and after showed the
difference: with that line alone the result was `status=breach unrelayed=1`; the
orchestrator then rewrote its own entry in the checker's exact words and the result became
`DECLINED`. Thirteen further checks in the same deployment required a literal phrase in
model-written text, including five verbs for an outcome and a heading format down to the
date spelling. None of them measured anything a differently-worded correct answer would
have failed to do.

Corollary: when a check must look at prose because nothing else records the fact, that is a
missing field, not a parsing problem. Add the field.

## How to add a behaviour

1. Write the gate or check first, with a test that replays the incident (the incident IS the
   fixture: the exact message, the exact pane, the exact log line). Point it at a
   machine-written field, per the section above.
2. Wire it where the action happens: a PreToolUse hook on the tool, a git hook, a refusal in
   the script that would do the harm. Hooks are listed in the deployment's
   `.claude/settings.json` (project) and `~/.claude/settings.json` (user); edit both. Claude
   Code loads a changed hook list into running sessions (measured on 2.1.263).
3. Add the row here. Then, and only then, the card line in the standing rules, naming the
   mechanism in parentheses.
4. A rule that cannot be gated or checked is written as UNENFORCED with an owner and a date.

## Hook wiring (see `docs/STANDING-RULES.md` for the JSON)

- PreToolUse on the connector send tools: `gate-outbound-draft.sh`, then `gate-outbound-reply.sh`.
- PostToolUse on the same tools: `record-outbound-send.sh`.
- PreToolUse `Read`: `gate-read-size.sh`. PreToolUse/PostToolUse `Agent`: `fable-call-log.sh`.
- PreToolUse `Bash`: `gate-rm-glob-var.sh`. Wire it at user level too, or a sub-agent's shell is ungated.
- SessionStart, UserPromptSubmit: `standing-rules.sh`.
