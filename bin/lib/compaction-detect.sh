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
#   _ceiling_state      stdin = LIVE pane text -> '' | warn | limit | compact-failed
#
# _ceiling_state exists because the idle-gated /context probe never runs while the
# session is BUSY, yet a busy session climbing to the ceiling renders these states
# right in the pane chrome (no /context needed). The watchdog checks this every
# cycle, busy or not, so a near-full / wedged orchestrator is acted on + alerted
# instead of silently dying at the unrecoverable ceiling (where compaction fails).

# parse_context_pct: stdin = captured /context pane text -> the total context %.
# Tries formats in order of reliability:
#   1) status footer   "98% context used"
#   2) near-full warn  "Context is 96% full"
#   3) total line      "931.6k/1m tokens (93%)" (anchored on the "/<size> tokens"
#      so the decimal per-category lines, which lack the slash, never match)
#   4) free-space line "Free space: 923.3k (92.3%)" -> used = 100 - free.
#      Claude Code 2.1.170 dropped BOTH the "NN% context used" footer and the
#      "/<size> tokens (NN%)" total line from /context; the only whole-context
#      signal left is the free-space row. We floor the free decimal, which rounds
#      the derived used% UP (compact slightly early = the safe direction). This is
#      a fallback after the direct used%-formats above, so older versions that
#      still print a footer/total are read from it, not from this derivation.
parse_context_pct() {
  local out p free
  out="$(cat)"
  p="$(printf '%s' "$out" | grep -oiE '[0-9]+% context used'   | grep -oE '[0-9]+' | tail -1)"
  [ -z "$p" ] && p="$(printf '%s' "$out" | grep -oiE 'context is [0-9]+% full' | grep -oE '[0-9]+' | tail -1)"
  [ -z "$p" ] && p="$(printf '%s' "$out" | grep -oiE '/[0-9.]+[kKmM] tokens \([0-9]+%\)' | grep -oE '\([0-9]+%\)' | grep -oE '[0-9]+' | tail -1)"
  if [ -z "$p" ]; then
    free="$(printf '%s' "$out" | grep -oiE 'free space:[^(]*\([0-9.]+%\)' | grep -oE '\([0-9.]+%\)' | grep -oE '[0-9.]+' | tail -1)"
    [ -n "$free" ] && p=$(( 100 - ${free%.*} ))
  fi
  printf '%s' "$p"
}

# _ceiling_state: stdin = live pane text -> the most severe context-pressure state
# visible, in priority order (worst first). These strings render even when the
# session is busy, so the watchdog can catch them without a /context probe:
#   compact-failed : auto/manual compaction could not reduce below the limit
#                    (UNRECOVERABLE by compaction -> needs /clear+rebrief)
#   limit          : "Context limit reached" hard wall (turn cannot proceed)
#   warn           : "Context is NN% full" / "Autocompact will trigger soon"
#                    (near-full, still compactable -> force a compact now)
#   (empty)        : healthy
_ceiling_state() {
  local t; t="$(cat)"
  if printf '%s' "$t" | grep -qiE 'compaction failed|could not be reduced below'; then echo compact-failed; return; fi
  if printf '%s' "$t" | grep -qiE 'context limit reached'; then echo limit; return; fi
  if printf '%s' "$t" | grep -qiE 'context is [0-9]+% full|autocompact will trigger'; then echo warn; return; fi
  echo ''
}
