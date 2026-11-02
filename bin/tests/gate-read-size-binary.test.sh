#!/usr/bin/env bash
# gate-read-size.sh (rule 7) counted newlines in a PNG and refused it as "278 lines".
# Images, PDFs and any file `file` calls binary pass; a text file over 200 lines is still refused. Hermetic: temp dir.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$repo/bin/hooks/gate-read-size.sh"
TD="$(mktemp -d)"; trap 'rm -rf -- "$TD"' EXIT
export ORCH_HOME="$TD" TEAM_DIR="$TD" NOTIFY_SINK="$TD/notify.sink" WATCH_ALERT_SINK="$TD/watch.sink"
fail=0; ok() { printf '  ok   %s\n' "$1"; }; bad() { printf '  FAIL %s\n' "$1"; fail=1; }
run() { printf '%s' "$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Read","tool_input":{"file_path":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$TD")" \
  | bash "$GATE" 2>"$TD/err"; rc=$?; }

# a PNG with 300 newline bytes after its signature
python3 -c 'import sys; open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+b"\x00\n"*300)' "$TD/shot.png"
cp "$TD/shot.png" "$TD/shot-no-extension"
python3 -c 'import sys; open(sys.argv[1],"wb").write(b"%PDF-1.4\n"+b"\x00\xff\n"*300)' "$TD/doc.pdf"
seq 1 300 | sed 's/^/line /' > "$TD/long.md"
seq 1 150 > "$TD/short.md"

run "$TD/shot.png"; [ "$rc" = 0 ] && ok "PNG with 300 newline bytes passes" || bad "PNG refused (rc $rc): $(cat "$TD/err")"
run "$TD/shot-no-extension"; [ "$rc" = 0 ] && ok "binary file without an image extension passes" || bad "binary refused (rc $rc)"
run "$TD/doc.pdf"; [ "$rc" = 0 ] && ok "PDF passes" || bad "PDF refused (rc $rc)"
run "$TD/long.md"; [ "$rc" = 2 ] && grep -q "RULES IN FORCE 7" "$TD/err" && ok "300-line .md still refused" || bad "300-line .md not refused (rc $rc)"
run "$TD/short.md"; [ "$rc" = 0 ] && ok "150-line .md passes" || bad "short .md refused (rc $rc)"

[ "$fail" = 0 ] && echo "gate-read-size-binary: PASS" || { echo "gate-read-size-binary: FAIL"; exit 1; }
