#!/usr/bin/env bash
# observer-github-groundtruth.sh RECENT MERGES: `gh pr list --state merged` lists by creation date, so a PR
# created long ago and merged inside the window fell outside the newest N and was missing. The fetch now asks
# GitHub for merged:>=<cutoff>. A fake gh on PATH returns that PR only when that search is passed.
# Hermetic: temp dir, no network. Run: bin/tests/observer-github-groundtruth-merge-window.test.sh
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; trap 'rm -rf -- "$TD"' EXIT
export TEAM_DIR="$TD" NOTIFY_SINK="$TD/notify.log" WATCH_ALERT_SINK="$TD/watch.log"
mkdir -p "$TD/bin"
fail=0; ok() { printf '  ok   %s\n' "$1"; }; bad() { printf '  FAIL %s\n' "$1"; fail=1; }

# Fake gh: open list -> one row; merged list -> the old-created PR only with --search merged:>=..., otherwise only
# the newest-created merges. Every merged call's arguments are logged.
cat > "$TD/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--state open"*) echo "  #9001  APPROVED  CLEAN  draft=false  feat/x  open fixture" ;;
  *"--state merged"*)
    printf '%s\n' "$args" >> "$FAKE_GH_LOG"
    if [[ "$args" == *"--search merged:>="* ]]; then
      echo "  #42  merged $(date -u -d '-3 hours' '+%Y-%m-%dT%H:%M:%SZ')  fix/old-branch  old-created, recently merged"
    else
      for n in $(seq 6000 6019); do echo "  #$n  merged $(date -u -d '-30 hours' '+%Y-%m-%dT%H:%M:%SZ')  f/$n  newer-created"; done
    fi ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TD/bin/gh"
export PATH="$TD/bin:$PATH" FAKE_GH_LOG="$TD/gh-merged.log"
printf 'Example/repo\n' > "$TD/repos.conf"
export OBSERVER_GH_CONFIG="$TD/repos.conf" OBSERVER_GH_GROUNDTRUTH="$TD/out.txt"

echo "1. a PR created long ago and merged 3 h ago is listed under RECENT MERGES"
bash "$repo/bin/observer-github-groundtruth.sh" --force 2>"$TD/err.log"; rc=$?
[ "$rc" = 0 ] && grep -q '#42  merged' "$TD/out.txt" && ok "#42 listed" \
  || bad "rc=$rc; out: $(grep -A3 'RECENT MERGES' "$TD/out.txt" 2>/dev/null | head -4); err: $(tail -2 "$TD/err.log")"

echo "2. the merged fetch asks GitHub for the merge window and a limit of at least 100"
args="$(tail -1 "$FAKE_GH_LOG" 2>/dev/null)"
[[ "$args" == *"--search merged:>="* ]] && ok "--search merged:>=<cutoff> passed" || bad "args: $args"
limit="$(grep -oE -- '--limit [0-9]+' <<<"$args" | awk '{print $2}')"
[ "${limit:-0}" -ge 100 ] && ok "limit $limit" || bad "limit ${limit:-none}"

[ "$fail" = 0 ] && echo "observer-github-groundtruth-merge-window: PASS" || { echo "observer-github-groundtruth-merge-window: FAIL"; exit 1; }
