# team-dir-guard.sh: structural guard against a destructive op (rm -rf, truncate,
# mv-over) landing on a LIVE team run dir. Sourced, not executed.
#
# Born from the 2026-06-16 incident: an engine TEST set TEAM_DIR="$(mktemp -d)" and
# registered `trap 'rm -rf "$TEAM_DIR"' EXIT`, THEN sourced team-env.sh, which
# SILENTLY re-derived TEAM_DIR to the live run dir ($TEAM_REPO/.team-<run>). On exit
# the trap wiped the whole live run dir (ledger, launch tracker, evidence). The
# behavioural rule (memory self-test-no-destructive-ops-live-paths) already existed
# and was not enough, so this adds a STRUCTURAL backstop:
#   - team-env.sh now FAILS LOUD instead of silently overriding a pre-set TEAM_DIR
#     (see that file); this guard is the second layer for code that does its own rm.
#   - tests call tdg_assert_scratch_team_dir at the top (refuse to run unless
#     TEAM_DIR is an isolated temp dir) and wrap any cleanup with tdg_guard_rmrf.
#
# Requires nothing; safe to source anywhere. All functions print to stderr and
# return non-zero on refusal (never exit, so a caller chooses how to handle it),
# except tdg_assert_scratch_team_dir which is meant to gate a test and exits 1.

# Normalize a path (no trailing slash, resolve . and ..; symlinks left as-is when
# realpath is unavailable). Echoes the normalized path.
_tdg_norm() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then realpath -m -- "$p" 2>/dev/null && return 0; fi
  # Fallback (no realpath): resolve symlinks + . / .. by cd'ing into the dir, so a
  # symlink TO a live run dir cannot evade the basename/parent pattern check. If the
  # path does not exist yet, fall back to stripping a single trailing slash.
  if [ -d "$p" ]; then ( cd "$p" 2>/dev/null && pwd -P ) && return 0; fi
  printf '%s' "${p%/}"
}

# The claude test is shared with the roster and the kill sites (bin/lib/pid-identity.sh).
if ! declare -F proc_pid_is_claude_shape >/dev/null 2>&1 \
   && [ -f "$(dirname "${BASH_SOURCE[0]}")/pid-identity.sh" ]; then
  # shellcheck source=bin/lib/pid-identity.sh
  . "$(dirname "${BASH_SOURCE[0]}")/pid-identity.sh"
fi

# True (0) if <pid> is a claude process of ANY run (proc_pid_is_claude_shape: what it
# executes, never a word in its args, so a script started from a clone named
# claude-orchestrator is not a claude). No run environ is required: this guard judges
# other runs' directories too. Without the shared test (pid-identity.sh missing) a
# live pid counts as claude, since this guard errs toward refusing.
_tdg_pid_is_claude() {
  declare -F proc_pid_is_claude_shape >/dev/null 2>&1 || return 0
  proc_pid_is_claude_shape "$1"
}

# True (0) if <path> is, or is inside, a team run dir: a path whose basename is
# `.team` or `.team-<something>` AND that sits directly under an orchestrator clone
# (the parent holds bin/team-env.sh) — OR a path that carries a live team's state
# (an `active` file with a live `claude` pid, or a `state.md` next to a live one).
# Deliberately err toward refusing: a false "yes" only blocks an auto-rm (use
# reset.sh, which kills the team first), while a false "no" is how the incident
# wiped a live run dir.
tdg_is_live_run_dir() {
  local path norm base parent
  path="${1:-}"; [ -n "$path" ] || return 1
  norm="$(_tdg_norm "$path")"
  base="$(basename -- "$norm")"
  parent="$(dirname -- "$norm")"
  # Primary, deterministic rule: a `.team` / `.team-*` dir under an orchestrator
  # clone. This is the exact shape team-env.sh derives, so it catches the incident
  # path regardless of whether the team is up at the instant of the check.
  case "$base" in
    .team|.team-*)
      [ -f "$parent/bin/team-env.sh" ] && return 0
      ;;
  esac
  # Secondary: any dir that carries a running team's live roster (an active entry
  # whose pid is a live claude process). Catches a run dir under a non-standard name.
  if [ -f "$norm/active" ]; then
    local pid _w _r
    while IFS=$'\t' read -r pid _w _r || [ -n "${pid:-}" ]; do
      [ -n "${pid:-}" ] || continue
      if kill -0 "$pid" 2>/dev/null && _tdg_pid_is_claude "$pid"; then
        return 0
      fi
    done < "$norm/active"
  fi
  return 1
}

# Guarded rm -rf: refuse (loud, return 1) if <path> is a live team run dir; else
# remove it. Use this in a test/script cleanup trap instead of a bare `rm -rf`.
tdg_guard_rmrf() {
  local path="${1:-}"
  [ -n "$path" ] || { echo "tdg_guard_rmrf: empty path; refusing" >&2; return 1; }
  if tdg_is_live_run_dir "$path"; then
    echo "REFUSING rm -rf '$path': it is (or holds) a LIVE team run dir." >&2
    echo "  A destructive op must never target a live .team-* run dir (2026-06-16 incident)." >&2
    echo "  To tear a real team down use bin/reset.sh (it kills the team first). For a test," >&2
    echo "  use an isolated temp TEAM_DIR (mktemp -d) and never source team-env.sh in a way" >&2
    echo "  that re-derives TEAM_DIR onto the live run (set TEAM_DIR_ALLOW_OVERRIDE=1 if intended)." >&2
    return 1
  fi
  rm -rf -- "$path"
}

# Gate a test: require TEAM_DIR to be an ISOLATED scratch dir (under $TMPDIR / /tmp
# / /var/folders) and NOT a live run dir. Abort the test loudly (exit 1) otherwise,
# so a misconfigured test can never run a destructive op against a live run dir.
tdg_assert_scratch_team_dir() {
  local td="${TEAM_DIR:-}" norm
  if [ -z "$td" ]; then echo "tdg_assert_scratch_team_dir: TEAM_DIR is unset; a test must set it to a mktemp -d" >&2; exit 1; fi
  norm="$(_tdg_norm "$td")"
  if tdg_is_live_run_dir "$norm"; then
    echo "ABORT: TEAM_DIR='$td' resolves onto a LIVE team run dir. A test MUST use an isolated" >&2
    echo "       temp dir (TEAM_DIR=\"\$(mktemp -d)\") and must NOT source team-env.sh in a way that" >&2
    echo "       re-derives TEAM_DIR onto the live run. (2026-06-16 run-dir-wipe incident.)" >&2
    exit 1
  fi
  case "$norm" in
    "${TMPDIR:-/tmp}"/*|/tmp/*|/var/folders/*) : ;;
    *) echo "ABORT: TEAM_DIR='$td' is not an isolated scratch dir (expected under /tmp, \$TMPDIR, or /var/folders)." >&2
       echo "       A test must set TEAM_DIR to a mktemp -d. (2026-06-16 incident.)" >&2
       exit 1 ;;
  esac
}

# tdg_guard_rmrf_owned <path>: return 0 only if <path> is the run dir this session owns,
# so the caller may remove it; print why and return 1 otherwise. Called by bin/reset.sh and
# bin/cleanup.sh right before their `rm -rf "$TEAM_DIR"`. tdg_guard_rmrf above refuses every
# live run dir, which is right for a test but would refuse reset.sh's purpose: deleting the
# run dir of the run being reset. So the test here is ownership, not liveness.
# Ownership is derived again from TEAM_REPO and TEAM_RUN_ID with team-env.sh's rule (legacy:
# $TEAM_REPO/.team, per run: $TEAM_REPO/.team-$TEAM_RUN_ID). The second derivation is
# independent on purpose: when it disagrees with the caller's TEAM_DIR (a value inherited from
# another run, or an explicit TEAM_DIR_ALLOW_OVERRIDE=1 dir), the guard refuses instead of
# choosing. Any path that is not the canonical dir is refused, including one that is not a
# run dir at all: a guard that let an unrecognised path through could delete $HOME or /.
# The canonical dir must also sit directly in TEAM_REPO once both are normalised, and a
# TEAM_RUN_ID with a slash is refused: "x/../../y" resolves outside the clone, "x/../bin"
# onto one of its directories, and both would otherwise equal their own canonical path.
tdg_guard_rmrf_owned() {
  local path="${1:-}" norm canon repo_norm
  [ -n "$path" ] || { echo "tdg_guard_rmrf_owned: empty path; refusing" >&2; return 1; }
  if [ -z "${TEAM_REPO:-}" ]; then
    echo "REFUSING rm -rf '$path': TEAM_REPO is unset, so ownership cannot be established." >&2
    echo "  Source bin/team-env.sh first." >&2
    return 1
  fi
  case "${TEAM_RUN_ID:-}" in
    */*) echo "REFUSING rm -rf '$path': TEAM_RUN_ID='$TEAM_RUN_ID' contains a slash, so it does not name a run dir." >&2
         return 1 ;;
  esac
  norm="$(_tdg_norm "$path")"
  if [ -n "${TEAM_RUN_ID:-}" ]; then canon="$TEAM_REPO/.team-$TEAM_RUN_ID"; else canon="$TEAM_REPO/.team"; fi
  canon="$(_tdg_norm "$canon")"
  repo_norm="$(_tdg_norm "$TEAM_REPO")"
  if [ -z "$canon" ] || [ -z "$repo_norm" ] || [ "${canon%/*}" != "$repo_norm" ]; then
    echo "REFUSING rm -rf '$path': the run dir does not resolve to a directory directly in the clone." >&2
    echo "  resolves to: $canon" >&2
    echo "  clone:       $repo_norm  (TEAM_REPO='$TEAM_REPO' TEAM_RUN_ID='${TEAM_RUN_ID:-}')" >&2
    return 1
  fi
  if [ -z "$norm" ] || [ "$norm" != "$canon" ]; then
    echo "REFUSING rm -rf '$path': it is not the run dir this session owns." >&2
    echo "  target:    $norm" >&2
    echo "  canonical: $canon  (TEAM_REPO='$TEAM_REPO' TEAM_RUN_ID='${TEAM_RUN_ID:-}')" >&2
    echo "  A TEAM_DIR inherited from another run, or set by hand, is never removed here." >&2
    echo "  Unset TEAM_DIR (and TEAM_DIR_ALLOW_OVERRIDE) and re-run." >&2
    return 1
  fi
  return 0
}
