#!/usr/bin/env bash
# observer-nudge.sh: decide whether an observer verdict is worth a nudge.
#
# The observer's nudge is a full orchestrator turn: the orchestrator reads the
# advice, checks the flagged thing, answers. That is the right cost for a NEW
# recommendation and pure waste for a repeat. Two mechanisms decide "repeat":
#
#   1. The VERDICT SIGNATURE. The model must emit one line of fixed tokens,
#      "VERDICT: team=<..> models=<..> host=<..> flags=<..>"; only those tokens
#      form the key, so prose rewording of the headline never counts as change.
#      (Ported from a downstream fork, where keying on the headline had nagged
#      with reworded holds.)
#   2. The RE-NUDGE WINDOW. A signature seen within OBSERVER_RENUDGE_SEC does not
#      nudge again, even if a different signature came between. Measured on a
#      downstream fork 2026-09-01/02: on unchanged inputs (one role idle for days)
#      the model alternated flags=issue / flags=none and models=keep / models=down
#      pass to pass, so "changed signature" fired on nearly every other pass:
#      35 nudges in 30 hours, most of them overnight with the team idle. A
#      keyed dedupe cannot see an A/B/A/B oscillation; a window can.
#
# A failed or empty model call yields the constant "?|?|?|?" and is never a nudge.
# State is a small ring file of "<epoch> <signature>" lines so a daemon restart
# does not re-announce everything it already said.
#
# Env:
#   OBSERVER_RENUDGE_SEC=14400  a signature already nudged within this window stays silent
#   OBSERVER_NUDGE_RING=16      how many recent nudges the ring remembers

# _verdict_sig: stdin = model output -> "team|models|host|flags", lower-cased tokens
# only; a missing field is "?". Constant for a failed call.
_verdict_sig() {
  local out team models host flags
  out="$(cat)"
  team="$(printf '%s' "$out"   | grep -oiE 'team=[a-z]+'   | head -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')"
  models="$(printf '%s' "$out" | grep -oiE 'models=[a-z]+' | head -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')"
  host="$(printf '%s' "$out"   | grep -oiE 'host=[a-z]+'   | head -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')"
  flags="$(printf '%s' "$out"  | grep -oiE 'flags=[a-z]+'  | head -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')"
  printf '%s|%s|%s|%s' "${team:-?}" "${models:-?}" "${host:-?}" "${flags:-?}"
}

# observer_nudge_should <sig> <now-epoch> <ring-file>
#   returns 0 = nudge (and records it), 1 = stay silent.
observer_nudge_should() {
  local sig="$1" now="$2" ring="$3"
  local window="${OBSERVER_RENUDGE_SEC:-14400}" keep="${OBSERVER_NUDGE_RING:-16}"
  local ts s
  [ -n "$sig" ] || return 1
  case "$sig" in '?|?|?|?') return 1 ;; esac
  if [ -f "$ring" ]; then
    while read -r ts s; do
      case "$ts" in ''|*[!0-9]*) continue ;; esac
      if [ "$s" = "$sig" ] && [ $((now - ts)) -lt "$window" ]; then
        return 1
      fi
    done < "$ring"
  fi
  mkdir -p "$(dirname "$ring")" 2>/dev/null || true
  { [ -f "$ring" ] && tail -n "$((keep - 1))" "$ring"; printf '%s %s\n' "$now" "$sig"; } > "$ring.tmp.$$" 2>/dev/null \
    && mv -f "$ring.tmp.$$" "$ring" 2>/dev/null || rm -f "$ring.tmp.$$" 2>/dev/null
  return 0
}
