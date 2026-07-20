#!/usr/bin/env bash
# observer.sh: a periodic AI advisor on team right-sizing and host load.
#
# Unlike the api-watchdog and tmux-watchdog (mechanical: they recover stalls and
# crashes), the observer REASONS about efficiency. On a slow cadence it gathers
# host load, per-role idle/health, the unit pipeline, and bus throughput, asks a
# model for a grow/shrink/server recommendation, writes it where the dashboard
# and orchestrator can read it, and nudges the orchestrator when the advice
# changes. It RECOMMENDS, never acts: scaling stays the orchestrator's call.
#
# Env:
#   OBSERVER_DISABLED=1     do not run
#   OBSERVER_INTERVAL=900   seconds between observations (default 15 min)
#   OBSERVER_MODEL=sonnet   model for the recommendation (sonnet|haiku|opus|id)
#   OBSERVER_IDLE_SEC=1800  a role idle longer than this is shrink-eligible
#   OBSERVER_CALL_TIMEOUT=120  max seconds for one model call
#   OBSERVER_GH_DISABLED=1  do NOT fetch/fold in GitHub ground truth (default on)
#
# GitHub ground truth: each cycle the observer runs bin/observer-github-groundtruth.sh
# (self-gated to at most every OBSERVER_GH_MIN_INTERVAL secs), then folds the
# resulting file into the model context and adds a prompt rule forbidding
# unlabelled external-state claims. The fetcher is generic (repo list from CONFIG);
# with no config file it is a no-op, so this stays inert out of the box.
#
# Started once per run by bin/lib/team-spawn.sh (idempotent via a pidfile),
# same shape as the watchdogs.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"

interval="${OBSERVER_INTERVAL:-900}"
model="${OBSERVER_MODEL:-sonnet}"
idle_sec="${OBSERVER_IDLE_SEC:-1800}"
call_timeout="${OBSERVER_CALL_TIMEOUT:-120}"
obs_dir="$TEAM_DIR/observer"
mkdir -p "$obs_dir"
last_headline=""

# GitHub ground-truth file the fetcher writes and we fold into the model context.
# Keep in sync with the fetcher's default (OBSERVER_GH_GROUNDTRUTH).
gh_groundtruth="${OBSERVER_GH_GROUNDTRUTH:-$obs_dir/github-ground-truth.txt}"
export OBSERVER_GH_GROUNDTRUTH="$gh_groundtruth"

iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Refresh the GitHub ground-truth file (best-effort, self-gated by the fetcher's
# own min-interval). Never fatal: on any failure the fetcher keeps the last good
# file with its stale fetched_at, which is the visible signal we surface to the
# model below. Skipped entirely if OBSERVER_GH_DISABLED=1.
refresh_gh_groundtruth() {
  [ "${OBSERVER_GH_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/observer-github-groundtruth.sh" ] || return 0
  timeout "$(( call_timeout * 2 ))" "$repo/bin/observer-github-groundtruth.sh" >/dev/null 2>&1 || true
}

# Emit the GITHUB GROUND TRUTH block for the observation, with a computed age so
# the model can judge staleness. If the file is missing or its fetched_at is old,
# say so explicitly — an old/absent timestamp means the last fetch failed.
gh_groundtruth_block() {
  [ "${OBSERVER_GH_DISABLED:-0}" = "1" ] && { echo "  (GitHub ground truth disabled)"; return 0; }
  if [ ! -f "$gh_groundtruth" ]; then
    echo "  (no github-ground-truth file yet — fetcher has not produced one; treat ALL external PR/issue state as UNVERIFIED)"
    return 0
  fi
  local fa fa_epoch now age_min age_note
  fa="$(grep -m1 '^fetched_at:' "$gh_groundtruth" 2>/dev/null | sed 's/^fetched_at:[[:space:]]*//')"
  fa_epoch="$(date -u -d "${fa:-}" +%s 2>/dev/null || echo 0)"
  now="$(date -u +%s)"
  if [ "$fa_epoch" -gt 0 ]; then
    age_min=$(( (now - fa_epoch) / 60 ))
    if [ "$age_min" -ge 30 ]; then
      age_note="AGE ${age_min}m — STALE: the last fetch likely FAILED; do not trust these rows as current, treat as UNVERIFIED"
    else
      age_note="AGE ${age_min}m — fresh"
    fi
  else
    age_note="AGE unknown — treat as UNVERIFIED"
  fi
  echo "  [$age_note]"
  sed 's/^/  /' "$gh_groundtruth"
}

# Convert team-status IDLE tokens (3s, 12m, 1h, 2d) to seconds.
idle_to_sec() {
  case "$1" in
    *s) echo "${1%s}" ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *h) echo $(( ${1%h} * 3600 )) ;;
    *d) echo $(( ${1%d} * 86400 )) ;;
    *) echo 0 ;;
  esac
}

# Deliver a one-line advisory to the orchestrator. The observer has NO /is bus
# identity (it never registers a listener), and send.py has no --from flag, so
# the old `send.py --from observer` call errored out every time and was swallowed
# by `|| true` (observed: zero observer messages were ever delivered in an 8MB bus
# log). Use the same tmux pane nudge the api/compaction watchdogs use -- it needs
# no bus identity and is the proven path to the orchestrator. Best-effort.
post_orch() {
  local text="$1" win target
  [ -n "${TEAM_SESSION:-}" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  # Target the window named 'orchestrator' (fall back to window 0).
  win="$(tmux -L "$TEAM_TMUX" list-windows -t "$TEAM_SESSION" -F '#{window_index} #{window_name}' 2>/dev/null | awk '$2=="orchestrator"{print $1; exit}')"
  [ -n "$win" ] || win=0
  target="$TEAM_SESSION:$win"
  tmux -L "$TEAM_TMUX" send-keys -t "$target" C-u 2>/dev/null || return 0
  # Verified submit (team-env's tmux_submit): a single Enter left long observer
  # messages collapsed into an unsubmitted [Pasted text] block under load.
  tmux_submit "$target" "$text" || true
}

gather_metrics() {
  # Host
  read -r l1 l5 l15 _ < /proc/loadavg
  local ncpu mem claude_n claude_rss
  ncpu="$(nproc)"
  mem="$(free -m | awk '/^Mem:/{printf "%d/%d MiB (%d%%)", $3, $2, ($3/$2)*100}')"
  claude_n="$(pgrep -xc claude 2>/dev/null || echo 0)"
  claude_rss="$(ps -eo rss,comm 2>/dev/null | awk '$2=="claude"{s+=$1} END{printf "%.1f", s/1024/1024}')"

  # Roster (role, idle, health) via team-status
  local status roster idle_roles=0
  status="$(TEAM_RUN_ID="${TEAM_RUN_ID:-}" "$repo/bin/team-status.sh" 2>/dev/null)"
  roster="$(printf '%s\n' "$status" | awk '$3=="yes"||$3=="no"{print $1"\t"$5"\t"$6}')"
  while IFS=$'\t' read -r role idle health; do
    [ -z "$role" ] && continue
    [ "$(idle_to_sec "$idle")" -ge "$idle_sec" ] && idle_roles=$((idle_roles+1))
  done <<< "$roster"

  # Pipeline from the unit ledger. Parse each status line's FIRST token against
  # the known unit-status enum; count anything else as 'unparseable' instead of
  # mis-counting it as a unit (observed: narrative 'status:' journal lines were
  # inflating fake unit counts -- 8 stale snapshots of one workstream read as 8
  # units -- and triggered a 6h phantom-stall alarm). blocked-on:* collapses to
  # 'blocked-on'.
  local pipe goal
  if [ -f "$TEAM_DIR/state.md" ]; then
    pipe="$(grep -E '^status:' "$TEAM_DIR/state.md" 2>/dev/null \
      | sed -E 's/^status:[[:space:]]*//' \
      | awk '{
          tok=$1
          if (tok ~ /^blocked-on:/) tok="blocked-on"
          if (tok=="todo"||tok=="assigned"||tok=="acked"||tok=="in-progress"||tok=="blocked-on"||tok=="review"||tok=="integrating"||tok=="done"||tok=="deferred")
            c[tok]++
          else
            unp++
        }
        END{
          for (k in c) printf "%s=%s ", k, c[k]
          if (unp>0) printf "unparseable=%s", unp
        }')"
    goal="$(grep -A3 -iE '^#* *goal' "$TEAM_DIR/state.md" 2>/dev/null | tail -n +2 | grep -m1 -vE '^[[:space:]]*$' | sed 's/^[[:space:]]*//' | head -c 200)"
  fi

  # Bus throughput over the last interval (rough liveness)
  local buslog msgs="?"
  buslog="$HOME/.claude/data/inter-session/messages.log"
  [ -f "$buslog" ] && msgs="$(tail -n 400 "$buslog" 2>/dev/null | wc -l)"

  # Per-role model. Ground truth: the launch records under $TEAM_DIR/models/
  # (written by team-spawn.sh at spawn time). Fallback for runs started before
  # that existed: parse the live claude process args. Lets the observer spot
  # over/under-provisioned roles.
  local role_models="" disp="" f
  if [ -d "$TEAM_DIR/models" ]; then
    role_models="$(for f in "$TEAM_DIR/models"/*; do
      [ -f "$f" ] && printf '  %s: %s\n' "$(basename "$f")" "$(head -1 "$f")"
    done 2>/dev/null)"
  fi
  if [ -z "$role_models" ]; then
    role_models="$(ps -eo args 2>/dev/null \
      | grep -oE -- '--model [A-Za-z0-9._-]+ You are "[a-z0-9-]+"' \
      | sed -E 's/.*--model ([A-Za-z0-9._-]+) You are "([a-z0-9-]+)".*/  \2: \1/' \
      | sort -u)"
  fi
  # Dispositions: recommendations the orchestrator has ALREADY decided
  # ($TEAM_DIR/observer/dispositions.md; it appends one line per decided rec).
  # Surfacing them stops the observer re-raising a DECLINED rec every cycle — incl.
  # an operator model-pin, which is just a DECLINED model-change. Strip comment/
  # blank lines; cap to the recent tail so the prompt stays bounded.
  if [ -f "$TEAM_DIR/observer/dispositions.md" ]; then
    disp="$(grep -vE '^[[:space:]]*(#|$)' "$TEAM_DIR/observer/dispositions.md" 2>/dev/null | tail -n 40 | sed 's/^/  /')"
  fi

  cat <<EOF
HOST: load ${l1}/${l5}/${l15} on ${ncpu} vCPU; mem ${mem}; claude procs ${claude_n} (~${claude_rss} GiB RSS)
ROSTER (role, idle, health):
$(printf '%s\n' "$roster" | sed 's/^/  /')
ROLE MODELS (role: model):
${role_models:-  (none discoverable)}
DISPOSITIONS (already decided by the orchestrator; do NOT re-raise a DECLINED rec unless its cited facts changed):
${disp:-  (none)}
SHRINK-ELIGIBLE (idle >= ${idle_sec}s): ${idle_roles}
PIPELINE (unit status counts): ${pipe:-none}
GOAL: ${goal:-unknown}
BUS: ~${msgs} recent messages logged
GITHUB GROUND TRUTH (authoritative external PR/merge state; the ONLY sanctioned source for such claims):
$(gh_groundtruth_block)
EOF
}

build_prompt() {
  local metrics="$1"
  cat <<EOF
You are the read-only efficiency observer for a long-running team of Claude Code
agents (an orchestrator plus worker roles, each a separate process ~300-500 MiB).
The work is API-bound: CPU is usually near-idle; the real costs are RAM per live
role and the agents' API usage. You RECOMMEND only; you never act.

Each role also runs on a MODEL (haiku < sonnet < opus < fable, increasing
capability and cost; fable costs ~2x opus per token) and a thinking-EFFORT.
The standing rule: CORE roles whose mistakes are expensive -- orchestrator,
implementors (impl-*), testers (tester*), reviewers, releaser, infra -- stay on
a high model + high effort; NEVER suggest downgrading them below opus. Fable is
reserved for judgment-dense roles (orchestration, adversarial verification,
architecture); a fable role doing mechanical, bulk-read, or relay work is the
single most expensive misallocation here -- flag it for a downgrade to opus or
sonnet. AUXILIARY roles doing ancillary, low-stakes, mechanical or read-only
work (e.g. a scraper, reader, poller, doc-fetcher, simple display) do NOT need
opus: if one is over-provisioned, suggest sonnet or haiku + lower effort; if an
auxiliary role is failing/retrying on too small a model, suggest bumping it up.
The actuation point is model_for() in bin/lib/team-spawn.sh (tiered policy;
per-role override TEAM_MODEL_<ROLE>, tier overrides TEAM_MODEL_TOP /
TEAM_MODEL_DEFAULT), applied by retiring + respawning the role; the
orchestrator decides.

Some recommendations have ALREADY been decided by the orchestrator — see
DISPOSITIONS in the observation (date | ACCEPTED|DECLINED | rec | why). Do NOT
re-raise a DECLINED recommendation UNLESS the specific facts it cited have changed,
and if you do re-raise it, state what changed. This includes operator model-pins: a
DECLINED model change is a pin — never re-suggest it. Treat ACCEPTED dispositions as
done. Re-raising a settled disposition just burns the orchestrator's turn.

Current observation:
${metrics}

GROUND-TRUTH RULE (BINDING): Never assert external PR/issue/GitHub state (a PR is
open/merged/blocked/approved, a review is pending, a merge landed, etc.) that is
not present in the GITHUB GROUND TRUTH block above. That block is the only
sanctioned source for such claims. If you must infer external state that is not in
it — or if the block is missing, disabled, or its AGE marks it STALE — you MUST
label that statement "UNVERIFIED". Do not restate PR claims from the bus log,
dispositions, or the pipeline counts as fact; those are historical and were the
source of repeated DAY-OLD "blocked PR" claims. When the ground truth and an older
note disagree, the ground truth wins.

In <= 16 lines, give a concrete recommendation:
1) First line EXACTLY: "HEADLINE: <one terse sentence: grow/shrink/hold + host sizing>"
2) TEAM: which roles (if any) to retire now (idle and no in-flight unit) and why;
   whether to add a role (a backlog with no owner). If none, say "hold".
3) HOST: is the instance over/under-sized for this load? (Consider: API-bound, so
   idle CPU is expected; judge on RAM headroom and peak role count, not CPU.)
4) MODELS: for each NON-CORE role only, suggest model/effort up or down with a
   one-line reason; mark core roles "keep high". Do NOT suggest anything carrying a
   DECLINED disposition (incl. model-pins). If every role is core, settled by a
   disposition, or already right-sized, say "no change".
5) FLAGS: anything off (a role wedged, pipeline stalled, runaway memory). Else none.
Be specific and brief. Do not suggest acting yourself; the orchestrator decides.
EOF
}

observe_once() {
  local metrics prompt out headline
  refresh_gh_groundtruth
  metrics="$(gather_metrics)"
  prompt="$(build_prompt "$metrics")"
  out="$(timeout "$call_timeout" claude -p "$prompt" --model "$model" 2>/dev/null)"
  [ -z "$out" ] && out="(model call failed or timed out; metrics only)"
  headline="$(printf '%s\n' "$out" | grep -m1 -E '^HEADLINE:' | sed 's/^HEADLINE:[[:space:]]*//')"

  {
    echo "# Observer recommendation"
    echo "_$(iso) - model ${model}, every ${interval}s_"
    echo
    echo '## Metrics'
    echo '```'
    printf '%s\n' "$metrics"
    echo '```'
    echo
    echo '## Recommendation'
    printf '%s\n' "$out"
  } > "$obs_dir/latest.md"
  { echo "=== $(iso) ==="; printf '%s\n' "$out"; echo; } >> "$obs_dir/history.md"

  # Nudge the orchestrator only when the headline changes (avoid nagging).
  if [ -n "$headline" ] && [ "$headline" != "$last_headline" ]; then
    post_orch "observer: ${headline} (full advice: ${obs_dir}/latest.md)"
    last_headline="$headline"
  fi
  echo "$(iso) observer: ${headline:-no headline}"
}

# --once: run a single observation and exit (testing / external schedulers).
if [ "${1:-}" = "--once" ]; then
  observe_once
  exit 0
fi

echo "observer: starting team=${TEAM_SESSION:-?} run=${TEAM_RUN_ID:-legacy} interval=${interval}s model=${model} idle>=${idle_sec}s"
while :; do
  observe_once || echo "$(iso) observer: tick error (continuing)"
  sleep "$interval"
done
