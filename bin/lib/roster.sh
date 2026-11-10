# roster.sh: ledger + roster helpers shared by add-role.sh and retire-role.sh
# (B9 dynamic team scaling). Sourced, not executed. Requires team-env.sh already
# sourced (TEAM_DIR). All edits to the ledger are write-to-temp-then-rename, so a
# failed awk never truncates the ledger.

if ! declare -F proc_pid_is_run_claude >/dev/null 2>&1; then
  # shellcheck source=bin/lib/pid-identity.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pid-identity.sh"
fi

# True if pid is (still) THIS run's claude process: a claude by what it executes
# (native, npm or versions-path install) and this run's TEAM_RUN_ID/TEAM_DIR in its
# environ (pid-identity.sh proc_pid_is_run_claude, the check stop-team.sh uses). Feeds
# the cap count, the double-spawn check and auto-numbering, so a recycled pid must not
# count. "args contain claude" counted any process started from a path containing the
# word, such as this clone's own daemons.
is_claude() { proc_pid_is_run_claude "$1"; }

# True only if window id $1 belongs to THIS run's session ($TEAM_SESSION). Guards
# window operations (send-keys, kill-window) on an id read from active: ids are per
# tmux server, the team socket is shared by every run, and after a server restart
# ids start again at @0, so a stale id can name another run's window.
wid_in_session() {
  local wins
  [ -n "${1:-}" ] || return 1
  tmux has-session -t "$TEAM_SESSION" 2>/dev/null || return 1
  wins="$(tmux list-windows -t "$TEAM_SESSION" -F '#{window_id}' 2>/dev/null)" || return 1
  grep -qxF -- "$1" <<<"$wins"
}

# True if a window named $1 exists in THIS run's session ($TEAM_SESSION), the test start_one
# (bin/lib/team-spawn.sh) uses to skip a role as already present. A role whose line is missing
# from active (never written, or dropped) still has its window, so role_is_live alone misses it.
role_window_exists() {
  local wins
  [ -n "${1:-}" ] || return 1
  wins="$(tmux list-windows -t "$TEAM_SESSION" -F '#{window_name}' 2>/dev/null)" || return 1
  grep -qxF -- "$1" <<<"$wins"
}

_state_file() { echo "$TEAM_DIR/state.md"; }
_active_file() { echo "$TEAM_DIR/active"; }

# Ensure the ledger exists with the append-only sections the roster helpers need.
_ensure_state() {
  local f; f="$(_state_file)"
  [ -f "$f" ] && return 0
  mkdir -p "$TEAM_DIR"
  {
    echo "# Team state"
    echo
    echo "## decision-log"
    echo
    echo "## roster"
    echo
  } > "$f"
}

# Append a line at the end of a named markdown section: after the section's last
# non-blank content line and before the next "## "/"---"/EOF. Creates the section
# at EOF if it is absent. Reads $1, writes the result to stdout.
#   md_append_under <file> <section-header-line> <line-to-add>
md_append_under() {
  awk -v hdr="$2" -v add="$3" '
    { lines[NR] = $0 }
    END {
      hidx = 0
      for (i = 1; i <= NR; i++) if (lines[i] == hdr) { hidx = i; break }
      if (hidx == 0) {                       # section absent: append it at EOF
        for (i = 1; i <= NR; i++) print lines[i]
        if (NR > 0 && lines[NR] != "") print ""
        print hdr; print ""; print add
      } else {
        endidx = NR + 1                      # first line after the section
        for (i = hidx + 1; i <= NR; i++)
          if (lines[i] ~ /^## / || lines[i] == "---") { endidx = i; break }
        lastcontent = hidx                   # last non-blank line within section
        for (i = hidx + 1; i < endidx; i++) if (lines[i] != "") lastcontent = i
        for (i = 1; i <= lastcontent; i++) print lines[i]
        print add
        for (i = lastcontent + 1; i <= NR; i++) print lines[i]
      }
    }
  ' "$1"
}

# Append a dated bullet to a section, atomically. $1=section header, $2=text.
_append_section() {
  local f tmp; f="$(_state_file)"
  _ensure_state
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  if md_append_under "$f" "$1" "$2" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; return 1
  fi
}

# Append to the ledger decision-log. $1 = text (no leading bullet).
decision_log_append() { _append_section "## decision-log" "- $(date +%F) $1  [orchestrator]"; }

# Append a roster event. $1 = text, e.g. "+implementer2 (added: ETL gap)".
roster_append() { _append_section "## roster" "- $(date +%F) $1"; }

# Re-file a unit as todo (used by retire --force so in-flight work is never
# dropped): within the unit's block, set owner -> -, status -> todo, annotate
# notes. $1=unit id, $2=note. Returns non-zero if the unit block is not found.
refile_unit() {
  local f tmp unit note; f="$(_state_file)"; unit="$1"; note="${2:-re-filed on retire}"
  [ -f "$f" ] || return 1
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  # Match by the unit id (the text after "## unit:"), so an id containing spaces
  # works. When the target block has no notes: line, synthesise one at its end so
  # the re-file provenance is never lost.
  awk -v target="$unit" -v note="$note" '
    function endblock() { if (inblk && !noted) print "notes: (" note ")"; noted = 0 }
    BEGIN { inblk = 0; found = 0; noted = 0 }
    /^## unit:/ {
      endblock()
      hid = $0; sub(/^## unit:[ \t]*/, "", hid); sub(/[ \t]+$/, "", hid)
      inblk = (hid == target) ? 1 : 0; if (inblk) found = 1
      print; next
    }
    /^## / { endblock(); inblk = 0; print; next }
    {
      if (inblk && $0 ~ /^owner:/)  { print "owner: -"; next }
      if (inblk && $0 ~ /^status:/) { print "status: todo"; next }
      if (inblk && $0 ~ /^notes:/)  { noted = 1; print $0 " (" note ")"; next }
      print
    }
    END { endblock(); exit (found ? 0 : 1) }
  ' "$f" > "$tmp"
  local rc=$?
  if [ "$rc" -eq 0 ]; then mv "$tmp" "$f"; else rm -f "$tmp"; fi
  return "$rc"
}

# Print the unit ids currently owned by a role AND in an active (in-flight)
# state, one per line. Active = assigned, acked, in-progress, review,
# integrating, or any blocked-on:* . (todo/done/deferred/- are NOT in-flight.)
# owner: and status: may appear in either order within a unit block, so decide
# per block at the next header / EOF.
in_flight_units_for_role() {
  local f; f="$(_state_file)"
  [ -f "$f" ] || return 0
  awk -v role="$1" '
    function flush() {
      if (unit != "" && owner == role &&
          (active[status] || status ~ /^blocked-on/)) print unit
    }
    BEGIN {
      split("assigned acked in-progress review integrating", a, " ")
      for (i in a) active[a[i]] = 1
    }
    /^## unit:/ {
      flush()
      unit = $0; sub(/^## unit:[ \t]*/, "", unit); sub(/[ \t]+$/, "", unit)
      owner = ""; status = ""
    }
    /^owner:/   { owner = $2 }
    /^status:/  { status = $2 }
    END { flush() }
  ' "$f"
}

# Number of live (still-running) role entries recorded in active. This is what the
# team-size cap counts. Every live line counts: the worker roles, and also the
# orchestrator (start-orchestrator.sh records its own line) and the communicator
# (bin/communicator.sh records its line), so both count toward the cap.
live_role_count() {
  local f n=0 pid wid role; f="$(_active_file)"
  [ -f "$f" ] || { echo 0; return 0; }
  while IFS=$'\t' read -r pid wid role || [ -n "${pid:-}" ]; do
    [ -n "${pid:-}" ] || continue
    kill -0 "$pid" 2>/dev/null && is_claude "$pid" && n=$((n + 1))
  done < "$f"
  echo "$n"
}

# Print the live role names recorded in active, one per line. "Live" means the
# pid is alive AND still a claude process, so a recycled pid is not counted.
live_roles() {
  local f pid wid role; f="$(_active_file)"
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r pid wid role || [ -n "${pid:-}" ]; do
    [ -n "${pid:-}" ] || continue
    kill -0 "$pid" 2>/dev/null && is_claude "$pid" && printf '%s\n' "$role"
  done < "$f"
}

# True if a role name has a live entry in active.
role_is_live() {
  local want="$1" r
  while IFS= read -r r; do [ "$r" = "$want" ] && return 0; done < <(live_roles)
  return 1
}

# Pick the next free auto-numbered name for a base (base1, base2, ...) that is not
# already live and has no window in this run's session (start_one would skip such a
# name and spawn nothing). Prints the chosen name. $1 = base (no trailing digits).
next_role_number() {
  local base="$1" n=1
  while role_is_live "$base$n" || role_window_exists "$base$n"; do n=$((n + 1)); done
  echo "$base$n"
}
