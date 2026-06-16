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
      if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[c]laude'; then
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
