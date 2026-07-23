#!/usr/bin/env bash
# dreamer.sh: nightly memory consolidation ("dreaming") for a team run.
#
# The run's knowledge ledgers grow append-only and keep superseded entries:
# state.md accretes derive/challenge/re-derive chains, the decisions file keeps
# every intermediate verdict of closed sagas, observer/history.md restates the
# same skeleton every cycle. A ledger that only grows makes every compaction
# rehydration slower (roles/orchestrator.md), and stale notes have caused real
# misbehavior (phantom-stall alarms, day-old external-state claims). This job
# rewrites the settled past smaller and truer, offline, while the team sleeps.
#
# Design (docs/dreaming.md has the full rationale):
#   - The model emits an EDIT SCRIPT against exact section headers; application
#     is mechanical (bin/lib/dream-lib.sh). Unmentioned sections are kept
#     verbatim; hallucinated headers are rejected ops.
#   - Never destroys raw evidence: removed content is appended verbatim to the
#     greppable archives (state-archive.md, DECISIONS-archive.md, dreams/archive/)
#     BEFORE any swap; swaps are atomic with a lost-update guard.
#   - Open/fresh content is protected mechanically: no op may touch a section
#     younger than DREAMER_FRESH_HOURS or without a derivable date.
#   - Quiescence-gated: refuses to run unless every roster role is idle
#     (bin/role-activity.sh), checked twice with a settle gap, and holds a
#     flock; --force overrides for a supervised run.
#   - Every run writes dreams/report-<stamp>.md: op log, rejected ops, byte
#     deltas, unified diffs. Reverting a cycle = restoring from the archive.
#
# Artifacts (--artifact to limit; default all that exist):
#   observer   observer/history.md -> per-day digest + fresh tail (+ archive)
#   state      state.md            -> collapse settled chains -> state-archive.md
#   decisions  DECISIONS*.md       -> collapse resolved sagas -> <name>-archive.md
#   reports    reports/*.md        -> refresh reports/INDEX.md (additive only)
#   bank       durable memory bank (only when DREAMER_MEMORY_DIR is set):
#              promote strategic facts; engine-lesson diffs are STAGED under
#              dreams/proposed/, never applied (tracked files are human-review).
#
# Usage: dreamer.sh [--once] [--report-only|--dry-run] [--artifact <name>]
#                   [--force]
#   --report-only  full pipeline incl. model calls, but stage everything under
#                  dreams/staged/ and write the report; NO live file changes.
#   --force        skip the quiescence gate (supervised daytime run).
#
# Env:
#   DREAMER_DISABLED=1        do nothing
#   DREAMER_MODEL=opus        model for consolidation calls
#   DREAMER_EFFORT=           passed to claude --effort when set (e.g. xhigh)
#   DREAMER_CALL_TIMEOUT=1200 max seconds per model call
#   DREAMER_FRESH_HOURS=48    sections younger than this are untouchable
#   DREAMER_MAX_CALLS=12      hard cap on model calls per run
#   DREAMER_MEMORY_DIR=       path to the durable memory bank (optional)
#   DREAMER_CLAUDE_BIN=claude model CLI (tests point this at a stub)
#   DREAMER_ACTIVITY_CMD=     override role-activity command (tests)
#   DREAMER_SETTLE_SEC=20     gap between the two quiescence checks
#
# Run id: uses $TEAM_RUN_ID when set; else auto-discovers the most recently
# modified .team-r* dir in this clone (cron-friendly), else legacy .team/.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- flags ---------------------------------------------------------------
report_only=0; force=0; only_artifact=""
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ;;                                  # accepted for cron symmetry
    --report-only|--dry-run) report_only=1 ;;
    --force) force=1 ;;
    --artifact) shift; only_artifact="${1:-}" ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "dreamer: unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

[ "${DREAMER_DISABLED:-0}" = "1" ] && { echo "dreamer: disabled"; exit 0; }

# --- run discovery + env -------------------------------------------------
if [ -z "${TEAM_RUN_ID:-}" ]; then
  latest="$(ls -1dt "$repo"/.team-r*/ 2>/dev/null | head -1)"
  if [ -n "$latest" ]; then
    TEAM_RUN_ID="$(basename "$latest" | sed 's/^\.team-//')"
    export TEAM_RUN_ID
  fi
fi
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"
# shellcheck disable=SC1091
. "$repo/bin/lib/dream-lib.sh"

[ -d "$TEAM_DIR" ] || { echo "dreamer: no run dir at $TEAM_DIR"; exit 0; }

model="${DREAMER_MODEL:-opus}"
effort="${DREAMER_EFFORT:-}"
call_timeout="${DREAMER_CALL_TIMEOUT:-1200}"
fresh_hours="${DREAMER_FRESH_HOURS:-48}"
max_calls="${DREAMER_MAX_CALLS:-12}"
claude_bin="${DREAMER_CLAUDE_BIN:-claude}"
activity_cmd="${DREAMER_ACTIVITY_CMD:-$repo/bin/role-activity.sh}"
settle="${DREAMER_SETTLE_SEC:-20}"

stamp="$(date -u '+%Y%m%d-%H%M')"
dreams="$TEAM_DIR/dreams"
arch_dir="$dreams/archive/$stamp"
staged="$dreams/staged/$stamp"
tmp="$dreams/tmp"
report="$dreams/report-$stamp.md"
mkdir -p "$dreams" "$arch_dir" "$tmp"
[ "$report_only" -eq 1 ] && mkdir -p "$staged"
cutoff="$(( $(date -u +%s) - fresh_hours * 3600 ))"
calls_used=0

log() { printf '%s\n' "$*" >> "$report"; }
say() { printf '%s dreamer: %s\n' "$(dream_iso)" "$*"; }

# --- lock + quiescence ---------------------------------------------------
exec 9>"$dreams/.lock"
if ! flock -n 9; then
  say "another dreamer holds the lock; exiting"
  exit 0
fi

roster_quiet() {
  # Every role in the active roster must classify idle. Any working/delegating
  # role, or a classification failure, means NOT quiet.
  local role act ok=1
  [ -f "$TEAM_DIR/active" ] || return 0   # no roster = nothing to disturb
  while IFS=$'\t' read -r _pid _win role; do
    [ -n "$role" ] || continue
    act="$("$activity_cmd" "$role" 2>/dev/null)" || { ok=0; break; }
    case "$act" in idle) : ;; *) ok=0; break ;; esac
  done < "$TEAM_DIR/active"
  [ "$ok" -eq 1 ]
}

if [ "$force" -ne 1 ]; then
  if ! roster_quiet; then
    say "roster not quiescent; refusing (use --force for a supervised run)"
    exit 0
  fi
  sleep "$settle"
  if ! roster_quiet; then
    say "roster woke during settle window; refusing"
    exit 0
  fi
fi

# --- model call ----------------------------------------------------------
# Pure text-in/text-out: -p with the prompt on stdin (ledgers exceed ARG_MAX),
# no tools. Returns non-zero on timeout/empty output; callers skip the
# artifact rather than fail the run.
run_model() {
  local prompt_file="$1" out_file="$2"
  if [ "$calls_used" -ge "$max_calls" ]; then
    say "model-call budget exhausted ($max_calls); skipping remaining calls"
    return 1
  fi
  calls_used=$((calls_used+1))
  local -a cmd=( "$claude_bin" -p --model "$model" )
  [ -n "$effort" ] && cmd+=( --effort "$effort" )
  timeout "$call_timeout" "${cmd[@]}" < "$prompt_file" > "$out_file" 2>>"$dreams/dreamer.log"
  [ -s "$out_file" ]
}

# Common preamble for every consolidation prompt: the safety rules the model
# must follow. The applier enforces the mechanical ones regardless.
prompt_rules() {
  cat <<'EOF'
You are the nightly memory consolidator ("dreamer") for a team of AI agents.
You rewrite the SETTLED PAST of a ledger smaller and truer. Hard rules:
- NEVER touch open/unresolved items or anything from the last 48 hours; when
  unsure whether something is settled, leave it alone.
- Keep ALL information: collapse a chain of superseded entries to its TERMINAL
  state plus a one-line provenance note; do not drop facts that are not
  superseded by a later entry in the same file.
- Corrections beat their targets: if a later entry declares an earlier claim
  wrong (a false positive, a retraction), the terminal state is the corrected
  one; never resurrect the refuted claim.
- Do not restate a claim about EXTERNAL state (a PR merged, a deploy done, a
  file present) as current truth; keep it attributed with its date.
- Output ONLY the ops protocol below; no prose before, between, or after ops.
EOF
}

ops_protocol_help() {
  cat <<'EOF'
Ops protocol (exact):
  If nothing qualifies, output exactly:  <<<DREAM-NO-OPS>>>
  To collapse several sections into one terminal summary:
<<<DREAM-OP COLLAPSE>>>
<<<HEADER>>>## the exact full header line of the first section
<<<HEADER>>>## the exact full header line of another section in the chain
<<<REPLACEMENT>>>
## <a header for the collapsed section, keep the original date prefix style>
The terminal state, dense but complete: outcome, decision, key numbers, date.
(supersedes N archived entries)
<<<END-OP>>>
  To move a section to the archive with no replacement (pure dead weight,
  fully superseded elsewhere):
<<<DREAM-OP ARCHIVE>>>
<<<HEADER>>>## the exact full header line
<<<END-OP>>>
HEADER lines must be byte-exact copies of header lines from the file.
EOF
}

# --- shared ledger pass (state / decisions) ------------------------------
# consolidate_ledger <src> <archive_target> <label>
consolidate_ledger() {
  local src="$1" archive_target="$2" label="$3"
  [ -f "$src" ] || { log "- $label: no file, skipped"; return 0; }
  local ref eligible
  ref="$(stat -c '%s %Y' "$src")"

  # Cheap convergence check: bytes in sections old enough to touch. Below the
  # floor there is nothing worth a model call (already consolidated).
  eligible="$(dream_sections_index "$src" | awk -F'\t' -v c="$cutoff" \
    '$3 > 0 && $3 < c { n += ($2 - $1 + 1) } END { print n+0 }')"
  if [ "$eligible" -lt "${DREAMER_MIN_ELIGIBLE_LINES:-40}" ]; then
    log "- $label: only $eligible eligible lines, below floor; converged, no call"
    return 0
  fi

  local pfile="$tmp/$label.prompt" ofile="$tmp/$label.ops"
  {
    prompt_rules
    echo
    echo "The file below is '$label' ($(basename "$src")). Sections start at '##'/'###' lines."
    echo "Collapse settled derive/challenge/re-derive chains and resolved sagas to"
    echo "their terminal state; ARCHIVE fully superseded dead weight. Sections from"
    echo "the last 48h and undated sections are protected (ops on them are rejected)."
    echo
    ops_protocol_help
    echo
    echo "----- FILE START -----"
    cat "$src"
    echo "----- FILE END -----"
  } > "$pfile"

  if ! run_model "$pfile" "$ofile"; then
    log "- $label: model call failed/skipped; untouched"
    return 0
  fi
  if grep -q '^<<<DREAM-NO-OPS>>>' "$ofile"; then
    log "- $label: model reports nothing to consolidate"
    return 0
  fi

  local opsdir="$tmp/$label.opsdir" nops
  rm -rf "$opsdir"
  nops="$(dream_parse_ops "$ofile" "$opsdir" 2>>"$dreams/dreamer.log")"
  if [ -z "$nops" ] || [ "$nops" -eq 0 ]; then
    log "- $label: no valid ops parsed; untouched"
    return 0
  fi

  local newf="$tmp/$label.new" archf="$tmp/$label.arch" rej="$tmp/$label.rej"
  if ! dream_apply_ops "$src" "$opsdir" "$nops" "$cutoff" "$newf" "$archf" "$rej"; then
    log "- $label: all $nops ops rejected:"
    sed 's/^/    /' "$rej" >> "$report"
    return 0
  fi

  local old_sz new_sz
  old_sz="$(stat -c%s "$src")"; new_sz="$(stat -c%s "$newf")"
  log "- $label: ops=$nops applied, $old_sz -> $new_sz bytes"
  [ -s "$rej" ] && { log "  rejected ops:"; sed 's/^/    /' "$rej" >> "$report"; }

  # Full diff into the archive dir; capped excerpt into the report.
  diff -u "$src" "$newf" > "$arch_dir/$label.diff" 2>/dev/null || true
  log '  diff (first 60 lines; full: '"$arch_dir/$label.diff"'):'
  { echo '```diff'; head -60 "$arch_dir/$label.diff"; echo '```'; } >> "$report"

  if [ "$report_only" -eq 1 ]; then
    cp "$newf" "$staged/$(basename "$src")"
    cp "$archf" "$staged/$(basename "$src").archived-sections"
    log "  report-only: staged under $staged, live file untouched"
    return 0
  fi

  # Archive FIRST (both the greppable ledger archive and the dated dream
  # archive), then swap with the lost-update guard.
  cp "$src" "$arch_dir/$(basename "$src").pre"
  {
    echo
    echo "===== dreamed $(dream_iso) from $(basename "$src") ====="
    cat "$archf"
  } >> "$archive_target"
  if dream_swap "$src" "$newf" "$ref"; then
    log "  swapped; originals in $(basename "$archive_target") + $arch_dir/"
  else
    log "  SWAP REFUSED (file changed mid-run); no live change, archive block already appended"
  fi
}

# --- observer history pass ----------------------------------------------
# Mechanical split by '=== <iso> ===' entries; whole days older than the
# fresh window are digested (model per-day summary, mechanical fallback) into
# history-digest.md, raw entries archived, history.md keeps the fresh tail.
consolidate_observer() {
  local src="$TEAM_DIR/observer/history.md"
  [ -f "$src" ] || { log "- observer: no history.md, skipped"; return 0; }
  local ref digest="$TEAM_DIR/observer/history-digest.md"
  ref="$(stat -c '%s %Y' "$src")"
  local cutoff_day
  cutoff_day="$(date -u -d "@$cutoff" '+%Y-%m-%d')"

  # Split entries: old (entry date < cutoff day, and day not yet digested)
  # vs keep. Entry delimiter: ^=== <ISO> ===
  local oldf="$tmp/obs.old" keepf="$tmp/obs.keep" daysf="$tmp/obs.days"
  awk -v cd="$cutoff_day" -v oldf="$oldf" -v keepf="$keepf" '
    /^=== [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
      d = substr($2, 1, 10)
      cur = (d < cd) ? oldf : keepf
      if (d < cd) days[d] = 1
    }
    { if (cur != "") print > cur; else print > keepf }
    END { for (d in days) print d }
  ' "$src" | sort > "$daysf"

  if [ ! -s "$oldf" ]; then
    log "- observer: nothing older than $cutoff_day; converged"
    return 0
  fi

  # Already-digested days (idempotency): skip any day present in the digest.
  local pending="$tmp/obs.pending"
  if [ -f "$digest" ]; then
    grep -oE '^## [0-9]{4}-[0-9]{2}-[0-9]{2}' "$digest" 2>/dev/null \
      | sed 's/^## //' | sort > "$tmp/obs.done" || : > "$tmp/obs.done"
  else
    : > "$tmp/obs.done"
  fi
  comm -23 "$daysf" "$tmp/obs.done" > "$pending"
  local n_old n_days
  n_old="$(grep -c '^=== ' "$oldf" || true)"
  n_days="$(wc -l < "$pending")"

  # Per-day material for the model: distinct headlines + flags, bounded.
  local mat="$tmp/obs.material"
  awk '
    /^=== / { d = substr($2,1,10) }
    /^HEADLINE:/ { key = d "|" $0; if (!(key in seen)) { seen[key]=1; print d "\t" $0 } }
    /^5\) FLAGS:|^FLAGS:/ { if ($0 !~ /none/) { key = d "|F|" $0; if (!(key in seen)) { seen[key]=1; print d "\tFLAG " $0 } } }
  ' "$oldf" > "$mat"

  local dfile="$tmp/obs.digest"
  : > "$dfile"
  if [ -s "$pending" ] && [ -s "$mat" ]; then
    local pfile="$tmp/obs.prompt" ofile="$tmp/obs.out"
    {
      prompt_rules
      echo
      echo "Below are (date, headline/flag) lines extracted from an observer daemon's"
      echo "15-minute snapshots. For EACH date listed in PENDING-DAYS, write a compact"
      echo "day digest: 2-6 lines covering what changed (verdict shifts, roster moves,"
      echo "flags); skip repetition. Output one block per day, exactly:"
      echo '<<<DREAM-OP DIGEST-DAY date=YYYY-MM-DD>>>'
      echo '...digest lines...'
      echo '<<<END-OP>>>'
      echo "No other output."
      echo
      echo "PENDING-DAYS:"; cat "$pending"
      echo
      echo "MATERIAL:"; cat "$mat"
    } > "$pfile"
    if run_model "$pfile" "$ofile"; then
      # Extract per-day blocks, accepting ONLY days in the pending list (a
      # model block for an already-digested day would duplicate its section).
      awk -v out="$dfile" -v pf="$pending" '
        BEGIN { while ((getline p < pf) > 0) if (p != "") pend[p] = 1; close(pf) }
        /^<<<DREAM-OP DIGEST-DAY date=/ {
          d = $0; sub(/^<<<DREAM-OP DIGEST-DAY date=/, "", d); sub(/>>>.*$/, "", d)
          ind = (d in pend); if (ind) print "## " d > out; next
        }
        /^<<<END-OP>>>/ { if (ind) print "" > out; ind = 0; next }
        ind { if ($0 !~ /^<<</) print > out }
      ' "$ofile"
    fi
  fi
  # Mechanical fallback for any pending day the model skipped: distinct
  # headlines list. Guarantees progress without model dependence.
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    grep -q "^## $d\$" "$dfile" 2>/dev/null && continue
    {
      echo "## $d"
      echo "_mechanical digest (model skipped this day): distinct headlines_"
      awk -F'\t' -v d="$d" '$1 == d { sub(/^HEADLINE:[[:space:]]*/, "", $2); print "- " $2 }' "$mat" | head -20
      echo
    } >> "$dfile"
  done < "$pending"

  # New history.md: pointer header + fresh entries only. Strip any previous
  # pointer header carried in the kept tail (idempotency across dreams).
  local newf="$tmp/obs.new"
  {
    echo "# Observer history (fresh tail)"
    echo "_older days are digested in history-digest.md; raw entries archived under dreams/archive/ (dreamer)_"
    echo
    grep -vE '^# Observer history \(fresh tail\)$|^_older days are digested in history-digest' "$keepf"
  } > "$newf"

  local old_sz new_sz
  old_sz="$(stat -c%s "$src")"; new_sz="$(stat -c%s "$newf")"
  log "- observer: $n_old entries over $n_days new day(s) digested; $old_sz -> $new_sz bytes"

  if [ "$report_only" -eq 1 ]; then
    cp "$newf" "$staged/observer-history.md"
    cp "$dfile" "$staged/observer-history-digest.add.md"
    gzip -c "$oldf" > "$staged/observer-history.archived.gz"
    log "  report-only: staged under $staged, live files untouched"
    return 0
  fi

  # Archive first, then digest append, then swap.
  gzip -c "$oldf" > "$arch_dir/observer-history.$stamp.md.gz"
  if [ ! -f "$digest" ]; then
    { echo "# Observer history digest"
      echo "_one section per day, written by the dreamer; raw entries in dreams/archive/_"
      echo; } > "$digest"
  fi
  cat "$dfile" >> "$digest"
  if dream_swap "$src" "$newf" "$ref"; then
    log "  swapped; raw archived to $arch_dir/observer-history.$stamp.md.gz; digest appended"
  else
    log "  SWAP REFUSED (history.md changed mid-run); digest appended, raw archive kept"
  fi
}

# --- reports index pass --------------------------------------------------
consolidate_reports() {
  local rdir="$TEAM_DIR/reports"
  [ -d "$rdir" ] || { log "- reports: no dir, skipped"; return 0; }
  local pfile="$tmp/reports.prompt" ofile="$tmp/reports.out" idxf="$rdir/INDEX.md"
  {
    prompt_rules
    echo
    echo "Below are the report files of this run (name, size, mtime, first lines)."
    echo "Write reports/INDEX.md: '# Report index' then ONE line per .md report:"
    echo '- `<filename>` (<yyyy-mm-dd>) - <what it concluded, <=120 chars>[; superseded by `<file>`]'
    echo "Mark superseded reports where a later report covers the same matter."
    echo "Output exactly:"
    echo '<<<DREAM-OP REPORT-INDEX>>>'
    echo '...full INDEX.md content...'
    echo '<<<END-OP>>>'
    echo
    local f
    for f in "$rdir"/*.md; do
      [ -f "$f" ] || continue
      [ "$(basename "$f")" = "INDEX.md" ] && continue
      echo "===== $(basename "$f") ($(stat -c%s "$f") bytes, $(date -u -d "@$(stat -c%Y "$f")" '+%Y-%m-%d')) ====="
      head -15 "$f"
      echo
    done
  } > "$pfile"
  if ! run_model "$pfile" "$ofile"; then
    log "- reports: model call failed/skipped; INDEX untouched"
    return 0
  fi
  local newf="$tmp/reports.index"
  awk '/^<<<DREAM-OP REPORT-INDEX>>>/{ind=1;next} /^<<<END-OP>>>/{ind=0} ind && $0 !~ /^<<</' "$ofile" > "$newf"
  if [ ! -s "$newf" ]; then
    log "- reports: empty index from model; untouched"
    return 0
  fi
  if [ "$report_only" -eq 1 ]; then
    cp "$newf" "$staged/reports-INDEX.md"
    log "- reports: INDEX staged ($(wc -l < "$newf") lines)"
  else
    [ -f "$idxf" ] && cp "$idxf" "$arch_dir/reports-INDEX.md.pre"
    mv -f "$newf" "$idxf"
    log "- reports: INDEX.md refreshed ($(wc -l < "$idxf") lines)"
  fi
}

# --- bank promotion pass -------------------------------------------------
# Promote strategic facts from tonight's consolidation into the durable
# memory bank. Ops: BANK-WRITE (full small-file content, filenames only, no
# path traversal) and PROPOSE (engine-lesson diffs -> dreams/proposed/, never
# applied). A rewritten MEMORY.md must still reference every entry file
# present after the ops, else that single write is rejected.
consolidate_bank() {
  local bank="${DREAMER_MEMORY_DIR:-}"
  [ -n "$bank" ] || { log "- bank: DREAMER_MEMORY_DIR unset, skipped"; return 0; }
  [ -d "$bank" ] || { log "- bank: $bank missing, skipped"; return 0; }

  # Tonight's delta: what the ledger passes archived/replaced, plus the fresh
  # ledger tail for context.
  local delta="$tmp/bank.delta"
  {
    echo "== consolidation ops applied tonight (from the report) =="
    cat "$report" 2>/dev/null
    echo
    echo "== fresh tail of state.md =="
    tail -n 120 "$TEAM_DIR/state.md" 2>/dev/null
  } > "$delta"

  local pfile="$tmp/bank.prompt" ofile="$tmp/bank.out"
  {
    prompt_rules
    echo
    echo "You maintain the durable memory bank: one markdown file per fact with"
    echo "frontmatter (name, description, metadata.type), indexed one-line-per-entry"
    echo "in MEMORY.md. Promote from tonight's delta ONLY facts with future-work"
    echo "value on OTHER tasks (recurring failure modes, environment facts, hard"
    echo "rules, operator preferences). Prefer UPDATING an existing entry over"
    echo "adding a near-duplicate; supersede, do not delete. Use frontmatter"
    echo "'sources:' provenance and 'valid_until:'/'superseded_by:' when"
    echo "invalidating. If nothing qualifies: <<<DREAM-NO-OPS>>>"
    echo
    echo "Ops (filenames only, no directories):"
    echo '<<<DREAM-OP BANK-WRITE path=some-entry.md>>>'
    echo '...full new file content...'
    echo '<<<END-OP>>>'
    echo "For a change to ENGINE/tracked files (roles/*.md, CLAUDE.md, bin/*):"
    echo '<<<DREAM-OP PROPOSE title=short-title>>>'
    echo '...proposed diff or precise change description + rationale...'
    echo '<<<END-OP>>>'
    echo
    echo "== MEMORY.md (index) =="
    cat "$bank/MEMORY.md" 2>/dev/null || echo "(no index yet)"
    echo
    echo "== entry files present =="
    ls -1 "$bank" 2>/dev/null
    echo
    echo "== tonight's delta =="
    cat "$delta"
  } > "$pfile"

  if ! run_model "$pfile" "$ofile"; then
    log "- bank: model call failed/skipped; untouched"
    return 0
  fi
  if grep -q '^<<<DREAM-NO-OPS>>>' "$ofile"; then
    log "- bank: nothing to promote"
    return 0
  fi

  # Apply BANK-WRITE / PROPOSE blocks.
  local blocks="$tmp/bank.blocks"
  rm -rf "$blocks"; mkdir -p "$blocks"
  awk -v dir="$blocks" '
    function fin() { if (cur != "") close(cur); cur = "" }
    /^<<<DREAM-OP BANK-WRITE path=/ {
      fin(); n++
      p = $0; sub(/^<<<DREAM-OP BANK-WRITE path=/, "", p); sub(/>>>.*$/, "", p)
      print p > (dir "/" n ".path"); close(dir "/" n ".path")
      print "bank" > (dir "/" n ".kind"); close(dir "/" n ".kind")
      cur = dir "/" n ".content"; printf "" > cur; next
    }
    /^<<<DREAM-OP PROPOSE title=/ {
      fin(); n++
      t = $0; sub(/^<<<DREAM-OP PROPOSE title=/, "", t); sub(/>>>.*$/, "", t)
      print t > (dir "/" n ".path"); close(dir "/" n ".path")
      print "propose" > (dir "/" n ".kind"); close(dir "/" n ".kind")
      cur = dir "/" n ".content"; printf "" > cur; next
    }
    /^<<<END-OP>>>/ { fin(); next }
    cur != "" { if ($0 !~ /^<<</) print >> cur }
    END { fin() }
  ' "$ofile"

  local i=1 kind path content wrote=0 proposed=0
  while [ -f "$blocks/$i.kind" ]; do
    kind="$(cat "$blocks/$i.kind")"; path="$(cat "$blocks/$i.path")"; content="$blocks/$i.content"
    if [ ! -s "$content" ]; then i=$((i+1)); continue; fi
    if [ "$kind" = "propose" ]; then
      mkdir -p "$dreams/proposed"
      local slug
      slug="$(printf '%s' "$path" | tr -cs 'A-Za-z0-9' '-' | cut -c1-60)"
      cp "$content" "$dreams/proposed/$stamp-$slug.md"
      log "- bank: PROPOSAL staged: dreams/proposed/$stamp-$slug.md ($path)"
      proposed=$((proposed+1))
    else
      # Filenames only: reject traversal or non-markdown targets.
      case "$path" in
        */*|*..*|"") log "- bank: REJECTED write (bad path): $path"; i=$((i+1)); continue ;;
        *.md) : ;;
        *) log "- bank: REJECTED write (not .md): $path"; i=$((i+1)); continue ;;
      esac
      if [ "$path" = "MEMORY.md" ]; then
        # Index-integrity gate: every entry file must still be referenced.
        local missing=""
        local f
        for f in "$bank"/*.md; do
          [ -f "$f" ] || continue
          [ "$(basename "$f")" = "MEMORY.md" ] && continue
          grep -qF "$(basename "$f")" "$content" || missing="$missing $(basename "$f")"
        done
        if [ -n "$missing" ]; then
          log "- bank: REJECTED MEMORY.md rewrite (drops:$missing)"
          i=$((i+1)); continue
        fi
      fi
      if [ "$report_only" -eq 1 ]; then
        mkdir -p "$staged/bank"
        cp "$content" "$staged/bank/$path"
        log "- bank: staged write: $path"
      else
        [ -f "$bank/$path" ] && cp "$bank/$path" "$arch_dir/bank-$path.pre"
        cp "$content" "$bank/$path"
        log "- bank: wrote $path ($(stat -c%s "$bank/$path") bytes)"
      fi
      wrote=$((wrote+1))
    fi
    i=$((i+1))
  done
  log "- bank: $wrote write(s), $proposed proposal(s)"
}

# --- run -----------------------------------------------------------------
{
  echo "# Dream report $stamp"
  echo "_$(dream_iso) | model=$model effort=${effort:-default} fresh=${fresh_hours}h mode=$([ "$report_only" -eq 1 ] && echo report-only || echo apply)$([ "$force" -eq 1 ] && echo ' FORCED')_"
  echo
  echo "## Operations"
} > "$report"

want() { [ -z "$only_artifact" ] || [ "$only_artifact" = "$1" ]; }

want observer  && consolidate_observer
want state     && consolidate_ledger "$TEAM_DIR/state.md" "$TEAM_DIR/state-archive.md" "state"
want decisions && {
  # Any DECISIONS-*.md at the run root (deployments name the operator file
  # differently, e.g. DECISIONS-FOR-FARES.md); archive target mirrors the name.
  found=0
  for f in "$TEAM_DIR"/DECISIONS*.md; do
    [ -f "$f" ] || continue
    case "$f" in *-archive.md) continue ;; esac
    found=1
    base="$(basename "$f" .md)"
    consolidate_ledger "$f" "$TEAM_DIR/$base-archive.md" "$base"
  done
  [ "$found" -eq 0 ] && log "- decisions: no DECISIONS*.md, skipped"
}
want reports   && consolidate_reports
want bank      && consolidate_bank

{
  echo
  echo "## Summary"
  echo "- model calls used: $calls_used / $max_calls"
  echo "- archives: $arch_dir"
  [ "$report_only" -eq 1 ] && echo "- staged (report-only): $staged"
  echo "- revert: restore any file from $arch_dir/*.pre; archived sections are"
  echo "  appended verbatim in state-archive.md / DECISIONS*-archive.md."
} >> "$report"
cp -f "$report" "$dreams/latest-report.md"

# Leave a self-announcing pointer near the top of state.md so the orchestrator
# sees the dream on its next ledger read (no pane nudge: it may be asleep, and
# a nudge would start a paid turn). Idempotent: replaces the previous marker.
# Same lost-update guard as every other ledger write: build a copy, re-stat,
# atomic swap on the SAME filesystem; skip silently if the orchestrator wrote
# in between (the report still exists either way).
if [ "$report_only" -ne 1 ] && [ -f "$TEAM_DIR/state.md" ]; then
  marker="_last dream: $stamp, report: dreams/report-$stamp.md_"
  mfile="$dreams/.marker.tmp"
  mref="$(stat -c '%s %Y' "$TEAM_DIR/state.md")"
  if grep -q '^_last dream: ' "$TEAM_DIR/state.md"; then
    # replace the first marker, drop any stale extras
    awk -v m="$marker" '
      /^_last dream: / { if (!done) { print m; done = 1 }; next }
      { print }
    ' "$TEAM_DIR/state.md" > "$mfile"
  else
    awk -v m="$marker" 'NR == 1 { print; print m; next } { print }' \
      "$TEAM_DIR/state.md" > "$mfile"
  fi
  if dream_swap "$TEAM_DIR/state.md" "$mfile" "$mref" 2>/dev/null; then
    :
  else
    rm -f "$mfile"
    say "dream marker skipped (ledger changed mid-write); report still at $report"
  fi
fi

# Empty archive dir (nothing applied) is noise; drop it.
rmdir "$arch_dir" 2>/dev/null || true
rm -rf "$tmp"
say "done: report at $report (calls=$calls_used)"
