#!/usr/bin/env bash
# compaction-detect.sh: pure, stdin-based parser for the orchestrator's total
# context %, read from `/context` output. Factored out of compaction-watchdog.sh
# so it can be unit-tested without a live tmux session or the daemon loop.
#
# Why this exists: Claude Code has rendered the context total in several formats
# across versions. The watchdog originally keyed ONLY on the parenthesised total
# "931.6k/1m tokens (93%)". Claude Code 2.1.x moved the authoritative total to a
# status footer "98% context used" (no parens) and, near the ceiling, a warning
# "Context is 96% full"; the parenthesised values left in view became decimal
# per-category lines like "(1.3%)" that the integer pattern never matched. The
# probe then silently returned empty ("could not read context %") and the
# orchestrator drifted to the auto-compact ceiling unmanaged. This parser reads
# all known formats so a future format tweak degrades to one fallback, not blind.
#
# Provided:
#   parse_context_pct   stdin = /context pane text -> echoes the integer % (or empty)

# parse_context_pct: stdin = captured /context pane text -> the total context %.
# Tries formats in order of reliability:
#   1) status footer   "98% context used"
#   2) near-full warn  "Context is 96% full"
#   3) total line      "931.6k/1m tokens (93%)" (anchored on the "/<size> tokens"
#      so the decimal per-category lines, which lack the slash, never match)
parse_context_pct() {
  local out p
  out="$(cat)"
  p="$(printf '%s' "$out" | grep -oiE '[0-9]+% context used'   | grep -oE '[0-9]+' | tail -1)"
  [ -z "$p" ] && p="$(printf '%s' "$out" | grep -oiE 'context is [0-9]+% full' | grep -oE '[0-9]+' | tail -1)"
  [ -z "$p" ] && p="$(printf '%s' "$out" | grep -oiE '/[0-9.]+[kKmM] tokens \([0-9]+%\)' | grep -oE '\([0-9]+%\)' | grep -oE '[0-9]+' | tail -1)"
  printf '%s' "$p"
}
