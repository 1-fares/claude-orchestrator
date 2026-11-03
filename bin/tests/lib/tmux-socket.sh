#!/usr/bin/env bash
# tmux-socket.sh: remove a test's own tmux socket FILE, not just its server.
#
# `tmux -L <name> kill-server` stops the server but leaves the socket file in
# ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/, so every test run left one more file behind.
# These helpers act on the one exact path a test created; never a glob.
#
#   . "$repo/bin/tests/lib/tmux-socket.sh"
#   tmux_sock_path <name>              # prints the path tmux uses for -L <name>
#   tmux_kill_unlink <tmux-bin> <name> # kill-server, then remove that socket file

tmux_sock_path() {
  printf '%s/tmux-%s/%s\n' "${TMUX_TMPDIR:-/tmp}" "$(id -u)" "$1"
}

tmux_kill_unlink() {
  local bin="${1:-tmux}" name="${2:-}" p
  [ -n "$name" ] || return 1
  p="$(tmux_sock_path "$name")"
  "$bin" -L "$name" kill-server 2>/dev/null || true
  if [ -S "$p" ]; then rm -f -- "$p"; fi
  return 0
}
