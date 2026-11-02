#!/usr/bin/env bash
# observer-github-groundtruth.sh: with no open PRs and no recent merges the section headers read "(0):".
# `grep -c` already prints 0 on no match (and exits 1), so a trailing `|| echo 0` printed a second 0 and a header
# read "(0" / "0):". A fake gh on PATH returns no rows. Hermetic: temp dir, no network.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; trap 'rm -rf -- "$TD"' EXIT
export TEAM_DIR="$TD" NOTIFY_SINK="$TD/notify.log" WATCH_ALERT_SINK="$TD/watch.log"
mkdir -p "$TD/bin"
fail=0; ok() { printf '  ok   %s\n' "$1"; }; bad() { printf '  FAIL %s\n' "$1"; fail=1; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$TD/bin/gh"; chmod +x "$TD/bin/gh"
export PATH="$TD/bin:$PATH"
printf 'Example/repo\n' > "$TD/repos.conf"
export OBSERVER_GH_CONFIG="$TD/repos.conf" OBSERVER_GH_GROUNDTRUTH="$TD/out.txt"

bash "$repo/bin/observer-github-groundtruth.sh" --force 2>"$TD/err.log"; rc=$?
[ "$rc" = 0 ] && ok "fetch rc 0" || bad "fetch rc=$rc: $(tail -2 "$TD/err.log")"
grep -qx 'OPEN PRs (0):' "$TD/out.txt" && ok "open header is 'OPEN PRs (0):'" \
  || bad "open header: $(grep -A1 'OPEN PRs' "$TD/out.txt" | head -2 | tr '\n' '|')"
grep -qE '^RECENT MERGES \(last [0-9]+h\) \(0\):$' "$TD/out.txt" && ok "recent header ends '(0):'" \
  || bad "recent header: $(grep -A1 'RECENT MERGES' "$TD/out.txt" | head -2 | tr '\n' '|')"
grep -qx '0' "$TD/out.txt" && bad "a bare '0' line is in the output" || ok "no bare '0' line"

[ "$fail" = 0 ] && echo "observer-github-groundtruth-zero-count: PASS" || { echo "observer-github-groundtruth-zero-count: FAIL"; exit 1; }
