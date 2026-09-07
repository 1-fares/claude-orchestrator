# Capability probe: prove the team can still work before and after a permission change

Every reduction of what the team may do (a least-privilege cloud policy, branch protection,
sudo rules, a rotated token) risks leaving it unable to work in a way nobody notices until
a unit fails hours later. The team cannot grant itself permissions, so the failure is a
human's problem and must reach a human as an `action`.

`bin/capability-probe.sh <probes.conf>` runs every privileged action the team depends on,
read-only or dry-run, and prints PASS or FAIL per probe. Conf format, one probe per line:

```
name | timeout_seconds | shell command (exit 0 = PASS)
```

Durable outputs: `$TEAM_DIR/reports/capability-probe.log` (append) and
`$TEAM_DIR/health/capability-probe.json` (last result). The observer's audit check (i)
reads the JSON and fails the pass when the result is older than 24 hours or has a FAIL.
A FAIL is reported through `bin/lib/notify.sh` as `action` unless `--no-notify` is given.

What a probe list should cover: cloud identity and every read the watches do; command
execution on the hosts the team manages (one harmless command through the same channel);
the repository reads and a dry-run push per working tree; the package registries the roles
install from; the local runtime (docker, sudo, tmux, the bus, the messaging connector, the
push topic); one model call. Keep every probe side-effect free.

## The staged plan for a permission reduction

1. **Measure.** Inventory the privileged actions from the code (grep the tools' calls),
   from the cloud audit trail (30 days of the role's events by API name), and from the
   host (sudo log). Write the probe list from the inventory; take a baseline: all PASS.
2. **Simulate.** Before changing a policy, check every action in the inventory against
   the proposed policy offline (for AWS: `iam simulate-principal-policy`). Zero denials.
3. **Change in a low-activity window, additive first.** Add the narrower grant before
   removing the broad one where the platform allows it; run the probe immediately.
4. **Watch.** For 48 hours after the removal, query the audit trail daily for access
   denials by the principal and keep the probe daily. Rollback is the reverse of the one
   command that removed the grant; write it down before the change.
5. **Close.** Record the result in the ledger; the observer keeps checking (i) daily.
