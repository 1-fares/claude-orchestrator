# dream-lib.sh: parsing/apply helpers for bin/dreamer.sh (nightly memory
# consolidation). Sourced, not executed. Tested directly by
# bin/tests/dreamer-editscript-test.sh.
#
# Contract (why this shape): the model NEVER rewrites a ledger wholesale. It
# emits an EDIT SCRIPT (ops) against exact section headers; application is
# mechanical, so any section the model does not mention is kept verbatim and
# a hallucinated header is a rejected op, not a corrupted file. Removed
# content is always appended verbatim to an archive file BEFORE the swap.
#
# Section model: a section starts at a line matching ^## or ^###, and runs to
# the line before the next such header. Lines before the first header are the
# prelude (never touched). A section's date comes from a YYYY-MM-DD in its
# header, else it inherits the most recent date seen in an earlier header
# (DECISIONS-style "### 20:07 - ..." entries under a dated parent); a section
# with no derivable date is PROTECTED (no op may touch it).
#
# Ops protocol (model output; anything outside op blocks is ignored):
#   <<<DREAM-NO-OPS>>>                          nothing to consolidate
#   <<<DREAM-OP COLLAPSE>>>
#   <<<HEADER>>>## exact header line
#   <<<HEADER>>>## another exact header line
#   <<<REPLACEMENT>>>
#   ...replacement text (becomes the collapsed section)...
#   <<<END-OP>>>
#   <<<DREAM-OP ARCHIVE>>>
#   <<<HEADER>>>## exact header line
#   <<<END-OP>>>
#
# Portability: no ERE {n} intervals (default awk on Ubuntu is mawk), no gawk
# extensions beyond (cmd | getline) with explicit close().

_DREAM_DATE_RE='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'

# dream_iso: UTC timestamp for reports/archives.
dream_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# dream_sections_index <file>
# Emit one TSV row per section: start<TAB>end<TAB>epoch-or-0<TAB>header
# (line numbers 1-based, end inclusive; epoch 0 = no derivable date =
# protected). The prelude (lines before the first header) is emitted as a
# row with header "(prelude)" and epoch 0; omitted when the file starts with
# a header.
dream_sections_index() {
  local file="$1"
  awk -v dre="$_DREAM_DATE_RE" '
    function flush(end) {
      if (hdr != "") printf "%d\t%d\t%s\t%s\n", start, end, date, hdr
      else if (end >= 1) printf "1\t%d\t0\t(prelude)\n", end
    }
    BEGIN { hdr=""; start=1; date=0; ctx=0 }
    /^##+ / {
      flush(NR-1)
      hdr=$0; start=NR
      if (match($0, dre)) {
        ds = substr($0, RSTART, RLENGTH)
        cmd = "date -u -d \"" ds "\" +%s 2>/dev/null"
        ctxv = 0
        (cmd | getline ctxv)
        close(cmd)
        if (ctxv > 0) ctx = ctxv
      }
      date = ctx
      next
    }
    END { flush(NR) }
  ' "$file"
}

# dream_parse_ops <opsfile> <workdir>
# Split the model output into per-op files under <workdir>:
#   NN.type (COLLAPSE|ARCHIVE), NN.headers (one exact header per line),
#   NN.replacement (COLLAPSE only). Echoes the op count. Lines outside op
# blocks are ignored (models sometimes add prose around the protocol).
# A structurally broken op (no headers; COLLAPSE without replacement) is
# dropped with a note on stderr rather than aborting the run.
dream_parse_ops() {
  local opsfile="$1" workdir="$2"
  mkdir -p "$workdir"
  awk -v dir="$workdir" '
    function fname(sfx) { return dir "/" (n+1) "." sfx }
    function closeall() {
      close(fname("type")); close(fname("headers")); close(fname("replacement"))
    }
    function endop(   ok) {
      if (!inop) return
      ok = (nh > 0)
      if (type == "COLLAPSE" && nr == 0) ok = 0
      closeall()
      if (ok) { n++ } else {
        printf "dream_parse_ops: dropping malformed %s op (headers=%d repl-lines=%d)\n", type, nh, nr > "/dev/stderr"
        system("rm -f \"" fname("type") "\" \"" fname("headers") "\" \"" fname("replacement") "\"")
      }
      inop=0; inrepl=0; nh=0; nr=0
    }
    /^<<<DREAM-OP (COLLAPSE|ARCHIVE)>>>[[:space:]]*$/ {
      endop()
      inop=1; inrepl=0; nh=0; nr=0
      type = ($0 ~ /COLLAPSE/) ? "COLLAPSE" : "ARCHIVE"
      print type > fname("type")
      printf "" > fname("headers")
      if (type == "COLLAPSE") printf "" > fname("replacement")
      next
    }
    /^<<<END-OP>>>[[:space:]]*$/ { endop(); next }
    inop && /^<<<HEADER>>>/ {
      h = $0; sub(/^<<<HEADER>>>/, "", h)
      print h >> fname("headers"); nh++; next
    }
    inop && /^<<<REPLACEMENT>>>[[:space:]]*$/ { inrepl=1; next }
    inop && inrepl {
      if ($0 ~ /^<<</) next   # protocol bleed inside replacement: drop the line
      print >> fname("replacement"); nr++; next
    }
    END { endop(); print n }
  ' "$opsfile"
}

# dream_apply_ops <src> <opsdir> <nops> <fresh_cutoff_epoch> <newfile_out> <archive_block_out> <rejects_out>
# Build the consolidated file and the archive block (removed sections,
# verbatim). Writes nothing to <src>. Validation per op (reject the op and
# continue, never abort the pass):
#   - every header matches EXACTLY ONE section (ambiguous/unknown -> reject)
#   - no section referenced by two ops (later op rejected)
#   - every referenced section is dated AND older than the fresh cutoff
# Returns 0 if at least one op applied, 1 if none.
dream_apply_ops() {
  local src="$1" opsdir="$2" nops="$3" cutoff="$4" newfile="$5" archfile="$6" rejects="$7"
  local idx i type hline row cnt start end date hdr applied=0
  idx="$(mktemp)"; : > "$newfile"; : > "$archfile"; : > "$rejects"
  dream_sections_index "$src" > "$idx"

  local -A claimed=() action=() replfile=()
  for (( i=1; i<=nops; i++ )); do
    [ -f "$opsdir/$i.type" ] || continue
    type="$(cat "$opsdir/$i.type")"
    local ok=1 first_start="" op_rows=()
    while IFS= read -r hline; do
      [ -n "$hline" ] || continue
      cnt="$(awk -F'\t' -v h="$hline" '$4 == h' "$idx" | wc -l)"
      if [ "$cnt" -ne 1 ]; then
        echo "op $i ($type): header not unique-or-found ($cnt matches): $hline" >> "$rejects"; ok=0; break
      fi
      row="$(awk -F'\t' -v h="$hline" '$4 == h {print; exit}' "$idx")"
      start="$(cut -f1 <<<"$row")"; date="$(cut -f3 <<<"$row")"
      if [ "$date" -eq 0 ] 2>/dev/null; then
        echo "op $i ($type): section has no derivable date (protected): $hline" >> "$rejects"; ok=0; break
      fi
      if [ "$date" -ge "$cutoff" ] 2>/dev/null; then
        echo "op $i ($type): section within fresh window (protected): $hline" >> "$rejects"; ok=0; break
      fi
      if [ -n "${claimed[$start]:-}" ]; then
        echo "op $i ($type): section already claimed by op ${claimed[$start]}: $hline" >> "$rejects"; ok=0; break
      fi
      op_rows+=("$start")
      [ -z "$first_start" ] && first_start="$start"
    done < "$opsdir/$i.headers"
    [ "$ok" -eq 1 ] || continue
    [ "${#op_rows[@]}" -gt 0 ] || continue
    for start in "${op_rows[@]}"; do
      claimed[$start]="$i"
      action[$start]="remove"
    done
    if [ "$type" = "COLLAPSE" ]; then
      action[$first_start]="replace"
      replfile[$first_start]="$opsdir/$i.replacement"
    fi
    applied=$((applied+1))
  done

  # Emit: walk sections in order; kept verbatim, replaced, or archived.
  while IFS=$'\t' read -r start end date hdr; do
    case "${action[$start]:-keep}" in
      keep)
        sed -n "${start},${end}p" "$src" >> "$newfile" ;;
      replace)
        cat "${replfile[$start]}" >> "$newfile"
        echo "_consolidated $(dream_iso) by dreamer; originals archived_" >> "$newfile"
        echo >> "$newfile"
        sed -n "${start},${end}p" "$src" >> "$archfile" ;;
      remove)
        sed -n "${start},${end}p" "$src" >> "$archfile" ;;
    esac
  done < "$idx"
  rm -f "$idx"
  [ "$applied" -gt 0 ]
}

# dream_index_line <entryfile>
# Emit "<type>\t- [<name>](<basename>) — <description>" from a bank entry's
# YAML frontmatter (name/description/metadata.type). Missing name falls back
# to the basename without .md; missing type to "reference". Used to maintain
# the MEMORY.md index deterministically (append-only), instead of trusting a
# model to rewrite the whole index without dropping entries.
dream_index_line() {
  local f="$1" base name desc type
  base="$(basename "$f")"
  # Read only the frontmatter block (between the first two '---' lines).
  name="$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$f")"
  desc="$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$f")"
  type="$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^[[:space:]]+type:/{sub(/^[[:space:]]*type:[[:space:]]*/,""); print; exit}' "$f")"
  name="${name:-${base%.md}}"
  type="${type:-reference}"
  # strip surrounding quotes and any leading list/type-union noise
  desc="${desc%\"}"; desc="${desc#\"}"
  type="${type%% *}"; type="${type%\"}"; type="${type#\"}"
  # keep the index line one-line and bounded
  desc="$(printf '%s' "$desc" | tr -d '\n' | cut -c1-200)"
  printf '%s\t- [%s](%s) — %s\n' "$type" "$name" "$base" "$desc"
}

# dream_append_index <memory_md> <entryfile...> -> writes a NEW MEMORY.md to
# stdout with an index line appended for each entry not already referenced,
# each under its "## <type>" section (created at EOF if absent). Append-only:
# existing lines are never modified or dropped. Idempotent: an entry whose
# basename already appears anywhere in the index is skipped.
dream_append_index() {
  local mem="$1"; shift
  local f base tsv
  local adds="$(mktemp)"
  for f in "$@"; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    grep -qF "($base)" "$mem" 2>/dev/null && continue   # already indexed
    dream_index_line "$f" >> "$adds"
  done
  if [ ! -s "$adds" ]; then rm -f "$adds"; cat "$mem"; return 0; fi
  awk -F'\t' -v addf="$adds" '
    BEGIN {
      while ((getline line < addf) > 0) {
        ti = index(line, "\t")
        t = substr(line, 1, ti-1); l = substr(line, ti+1)
        add[t] = add[t] l "\n"
      }
      close(addf)
    }
    # Buffer the whole file so we can insert at each section end.
    { buf[NR] = $0 }
    /^##[[:space:]]/ {
      # close the previous section: flush its pending adds before this header
      hdr = $0; sub(/^##[[:space:]]+/, "", hdr)
      sect[NR] = tolower(hdr)
    }
    END {
      # Walk lines; when a section (## <type>) ends, emit its adds.
      cur = ""
      for (i = 1; i <= NR; i++) {
        if (i in sect) {
          # entering a new section: first flush the one we were in
          if (cur != "" && (cur in add)) { printf "%s", add[cur]; delete add[cur] }
          cur = sect[i]
        }
        print buf[i]
      }
      # flush the last section
      if (cur != "" && (cur in add)) { printf "%s", add[cur]; delete add[cur] }
      # any types with no matching section: append under a new header
      for (t in add) {
        printf "\n## %s\n%s", t, add[t]
      }
    }
  ' "$mem"
  rm -f "$adds"
}

# dream_swap <src> <newfile> <ref_stat>
# Atomic replace with a lost-update guard: refuse when <src> changed since it
# was read (<ref_stat> = "size mtime" captured at read time). Preserves mode.
dream_swap() {
  local src="$1" newfile="$2" ref="$3" now
  now="$(stat -c '%s %Y' "$src" 2>/dev/null)"
  if [ "$now" != "$ref" ]; then
    echo "dream_swap: $src changed since read ($ref -> $now); refusing swap" >&2
    return 1
  fi
  chmod --reference="$src" "$newfile" 2>/dev/null || true
  mv -f "$newfile" "$src"
}
