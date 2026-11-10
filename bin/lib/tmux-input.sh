# shellcheck shell=bash
# tmux-input.sh: type into a Claude Code input box through tmux and OBSERVE each step. The sourcing script defines
# ti_tmux <tmux args...> (its own socket).
#
# Measured on real claude 2.1.312 panes, vim mode (bin/tests/fixtures/tmux-input/*.raw, 2026-11-02):
# - The box is the row that starts at column 0 with `❯` + U+00A0 (NOT a space), directly under a `─` separator.
#   Menu cursor rows (`   ❯ 2. Opus`, ` ❯ Yes, I trust`) and autocomplete rows are indented; scrollback has no separator
#   directly above. A picker such as /model replaces the box entirely.
# - An empty box shows a placeholder in dim (ESC[2m) right after the mark: `Try "..."`, `Press up to edit queued
#   messages`. Typed text carries no SGR.
# - INSERT shows "-- INSERT --" in the footer under the box (also while a turn runs); NORMAL and non-vim show none. In
#   NORMAL, typed text is read as commands: "try again" arrived as "gain", "/usage" as "age".
# - A menu or picker ends with a key-footer row that starts with its key and offers Esc: ` Enter to confirm · Esc to
#   cancel`, `   Enter to set as default · s to use this session only · Esc to cancel`. It sits on the row just above
#   the box separator, under an indented `❯` cursor row, or, when a picker or dialog (/model, /usage, the trust prompt)
#   has replaced the box, among the last rows of the screen (/usage ends in a bare `Esc to cancel`).
# - Dialogs with no box and other footers: /config `Type to filter · ... · Esc to clear`, /permissions `←/→ to switch ·
#   ↓ to select · Esc to cancel`, /resume `Ctrl+A to show all projects · ... · Esc to cancel`. /usage can show for a
#   moment with no footer drawn yet. tmux reports pane_current_command=claude for a claude pane.
TI_KEY_PAUSE="${TI_KEY_PAUSE:-0.3}"
TI_SETTLE_TRIES="${TI_SETTLE_TRIES:-10}"   # polls, TI_KEY_PAUSE apart, for typed text to appear in the box
TI_SUBMIT_TRIES="${TI_SUBMIT_TRIES:-4}"    # Enter presses before giving up
TI_SUBMIT_WAIT="${TI_SUBMIT_WAIT:-1}"      # seconds after each Enter before reading the box

_ti_key() { ti_tmux send-keys -t "$1" "$2" 2>/dev/null; local rc=$?; sleep "$TI_KEY_PAUSE"; return $rc; }

# _ti_scan <target>: read the screen once. Sets TI_HAS_BOX (0/1), TI_TEXT (box text, "" for empty or placeholder),
# TI_INSERT (0/1), TI_MENU (0/1). Exit 3 when the capture fails.
_ti_scan() {
  local cap out
  TI_HAS_BOX=0; TI_TEXT=""; TI_INSERT=0; TI_MENU=0
  cap="$(ti_tmux capture-pane -e -p -t "$1" 2>/dev/null)" || return 3
  out="$(printf '%s\n' "$cap" | sed $'s/\xc2\xa0/ /g' | awk '
    function footer(s) { return s ~ /^[[:space:]]*(Enter|Esc) to / && s ~ /Esc to cancel/ }
    function plain(s) { gsub(/\033\][^\033]*\033\\/, "", s); gsub(/\033\[[0-9;:?]*[A-Za-z]/, "", s); return s }
    { raw[NR] = $0; p[NR] = plain($0); if (p[NR] !~ /^[[:space:]]*$/) nb[++n] = NR }
    END {
      box = 0
      for (i = NR; i > 1; i--) if (p[i] ~ /^❯( |$)/ && p[i-1] ~ /^[[:space:]]*─/) { box = i; break }
      if (box) {
        t = p[box]; sub(/^❯ ?/, "", t); sub(/[[:space:]]+$/, "", t)
        r = raw[box]; k = index(r, "❯"); r = substr(r, k + length("❯")); sub(/^ /, "", r)
        if (r ~ /^\033\[2m/) t = ""
        if (t ~ /^Try "/ || t == "Press up to edit queued messages") t = ""
        ins = 0; for (i = box + 1; i <= NR; i++) if (p[i] ~ /-- INSERT --/) ins = 1
        # With a box on screen, a menu is a footer on the row just above the box separator AND an indented `❯` cursor row
        # above it in the same block: bash output can end in a line shaped like a footer, but has no cursor row.
        menu = 0
        for (i = box - 2; i > 0; i--) if (p[i] !~ /^[[:space:]]*$/) break
        if (i > 0 && footer(p[i]))
          for (j = i - 1; j > 0 && j > i - 15 && p[j] !~ /^[[:space:]]*─/; j--) if (p[j] ~ /^[[:space:]]+❯ /) { menu = 1; break }
        printf "1\n%d\n%d\n%s\n", ins, menu, t
      } else {
        # With no box the bottom rows belong to the dialog, so any key hint offering Esc marks one.
        menu = 0
        for (j = n; j > 0 && j > n - 3; j--) if (p[nb[j]] ~ /Esc to /) menu = 1
        printf "0\n0\n%d\n\n", menu
      }
    }')"
  { read -r TI_HAS_BOX; read -r TI_INSERT; read -r TI_MENU; IFS= read -r TI_TEXT; } <<<"$out"
  return 0
}

# Prints the box text (empty for an empty box). Exit 1: no box, so the state is unknown; 3: capture failed.
ti_input_line() {
  _ti_scan "$1" || return 3
  [ "$TI_HAS_BOX" = 1 ] || return 1
  printf '%s' "$TI_TEXT"
}
ti_shows_insert() { _ti_scan "$1" && [ "$TI_INSERT" = 1 ]; }
# A menu or picker takes Enter and digits as answers. Exit 0 when one is on screen.
ti_menu_open() { _ti_scan "$1" && [ "$TI_MENU" = 1 ]; }

# Put the box in INSERT (vim) or leave it as it is (non-vim), its text unchanged. Exit 0 ready to type, 1 not seen
# ready, 2 no box (nothing was sent). `A` appends at the end in NORMAL and is a literal in non-vim, removed again.
ti_force_insert() {
  local t="$1" before after
  _ti_scan "$t" || return 1
  [ "$TI_HAS_BOX" = 1 ] || return 2
  [ "$TI_MENU" = 1 ] && return 1
  [ "$TI_INSERT" = 1 ] && return 0
  before="$TI_TEXT"
  _ti_key "$t" A || return 1
  _ti_scan "$t" || return 1
  [ "$TI_INSERT" = 1 ] && [ "$TI_TEXT" = "$before" ] && return 0
  after="$TI_TEXT"
  if [ "$after" = "${before}A" ]; then
    _ti_key "$t" BSpace || return 1
    after="$(ti_input_line "$t")" || return 1
  fi
  [ "$after" = "$before" ]
}

# Empty the box; call after ti_force_insert. Exit 0 only when seen empty. TI_DISCARDED holds the text that was there,
# so the caller can log what it threw away.
ti_clear() {
  local t="$1" box
  box="$(ti_input_line "$t")" || return 1
  [ -z "$box" ] && return 0
  TI_DISCARDED="$box"
  _ti_key "$t" C-u
  box="$(ti_input_line "$t")" || return 1
  [ -z "$box" ] && return 0
  # `cc` clears the whole line in vim where C-u only kills back to the cursor, and leaves INSERT on.
  if ti_shows_insert "$t"; then
    _ti_key "$t" Escape; _ti_key "$t" c; _ti_key "$t" c
    box="$(ti_input_line "$t")" || return 1
  fi
  [ -z "$box" ]
}

# Type <text> after what the box holds and wait until the box shows exactly that (a pasted block for a long text).
# A stray prefix or a mangled text is a failure.
ti_type() {
  local t="$1" text="$2" before box want i=0
  before="$(ti_input_line "$t")" || return 1
  ti_tmux send-keys -t "$t" -l "$text" 2>/dev/null || return 1
  want="$before$text"
  while [ "$i" -lt "$TI_SETTLE_TRIES" ]; do
    sleep "$TI_KEY_PAUSE"
    box="$(ti_input_line "$t")" || return 1
    [ "$box" = "$want" ] && return 0
    # A text that wraps continues on rows without the prompt mark, so only its start is on the prompt row.
    if [ "${#want}" -gt 40 ]; then case "$box" in "${want:0:40}"*) return 0 ;; esac; fi
    case "$box" in "$before"'[Pasted text'*) return 0 ;; esac
    i=$((i + 1))
  done
  return 1
}

# Press Enter until the box is empty or gone (a dialog the text opened replaces it). Exit 1 if it never is. A box that
# still holds text (a pasted block's first Enter, an autocomplete that only completed) gets another Enter; none follows
# once the box is empty or gone, so a dialog the text opened never receives one.
ti_submit() {
  local t="$1" i=0
  while [ "$i" -lt "$TI_SUBMIT_TRIES" ]; do
    ti_tmux send-keys -t "$t" Enter 2>/dev/null || return 1
    sleep "$TI_SUBMIT_WAIT"
    _ti_scan "$t" || return 1
    [ "$TI_HAS_BOX" = 0 ] && return 0
    [ -z "$TI_TEXT" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# A pane with no box is typed into blind only when it is positively a shell: tmux reports a shell as its current
# command and its first process is not claude. Anything else, unreadable included, is refused: a claude dialog whose
# footer is not drawn yet must never get text and Enter (on /resume, Enter resumes another session).
_ti_pane_is_shell() {
  local cmd="" pid=""
  read -r cmd pid < <(ti_tmux display-message -p -t "$1" '#{pane_current_command} #{pane_pid}' 2>/dev/null)
  case "$cmd" in bash|sh|dash|zsh|ksh|mksh|fish|tcsh) ;; *) return 1 ;; esac
  [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = claude ] && return 1
  return 0
}

# ti_send <target> <text> [clear]: force INSERT, empty the box if asked, type, confirm, submit. Without clear, a box that
# holds text (a human's draft; the dim placeholder does not count) is refused before any key: a daemon never appends to,
# submits or deletes it. TI_REFUSED says why a send was refused; TI_DISCARDED is the text a clear threw away. Exit 0 only when the
# text was seen in the box and then seen gone; 1 failed or refused (a menu or picker open, a mode or text not as
# expected, or no box in a pane that is not positively a shell); 2 no box in a shell pane, nothing sent (the caller
# decides whether to type blind). With clear, a failure
# empties the box again, so a mangled text is not left for the next sender to append to.
ti_send() {
  local t="$1" text="$2" clear="${3:-}" rc
  TI_REFUSED=""; TI_DISCARDED=""
  _ti_scan "$t" || { TI_REFUSED="screen capture failed"; return 1; }
  [ "$TI_MENU" = 1 ] && { TI_REFUSED="a menu or dialog is open"; return 1; }
  if [ "$TI_HAS_BOX" != 1 ]; then
    _ti_pane_is_shell "$t" && return 2
    TI_REFUSED="no input box on a claude pane"; return 1
  fi
  if [ -z "$clear" ] && [ -n "$TI_TEXT" ]; then TI_REFUSED="the box holds typed text: $TI_TEXT"; return 1; fi
  ti_force_insert "$t"; rc=$?
  [ "$rc" = 0 ] || { TI_REFUSED="INSERT not reached"; return 1; }
  if [ -n "$clear" ]; then
    ti_clear "$t" || { TI_REFUSED="box not seen empty"; return 1; }
  else
    # Read again: a human may have started typing since the first scan.
    TI_TEXT="$(ti_input_line "$t")" || { TI_REFUSED="box unreadable"; return 1; }
    [ -z "$TI_TEXT" ] || { TI_REFUSED="the box holds typed text: $TI_TEXT"; return 1; }
  fi
  if ti_type "$t" "$text" && ti_submit "$t"; then return 0; fi
  TI_REFUSED="text not seen typed and submitted"
  # The box was seen empty before typing, so a leftover that can only be this send's own text (a prefix of it, or the
  # bare [Pasted text] marker of it) is removed. Anything else may hold keys a human typed during the send: it is left
  # alone and named in TI_REFUSED for the caller's log.
  local left kept="$TI_DISCARDED"
  left="$(ti_input_line "$t")" || return 1
  [ -z "$left" ] && return 1
  if [ "${text#"$left"}" != "$text" ] || [[ "$left" =~ ^\[Pasted\ text\ \#[0-9]+(\ \+[0-9]+\ lines)?\]$ ]]; then
    ! ti_menu_open "$t" && ti_force_insert "$t" && ti_clear "$t"
    TI_DISCARDED="$kept"
  else
    TI_REFUSED="$TI_REFUSED; the box now holds [$left], not only this send's text: left alone"
  fi
  return 1
}
