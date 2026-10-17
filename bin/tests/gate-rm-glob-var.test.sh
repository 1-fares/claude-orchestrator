#!/usr/bin/env bash
# gate-rm-glob-var.test.sh: the PreToolUse(Bash) guard refuses rm/unlink/xargs rm/find -delete with a wildcard
# or a variable in the path (operator ruling, 2026-10-17), and leaves literal paths and data alone.
# Pure: feeds JSON payloads to the hook; nothing is ever executed or removed.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
G="$repo/bin/hooks/gate-rm-glob-var.sh"
fail=0
run() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" | bash "$G" 2>/tmp/.gate-rm-glob-var.err.$$; }
block() { run "$1"; rc=$?; if [ "$rc" = 2 ]; then printf '  ok   BLOCK  %s\n' "$1"; else printf '  FAIL BLOCK  %s (rc=%s)\n' "$1" "$rc"; fail=1; fi; }
allow() { run "$1"; rc=$?; if [ "$rc" = 0 ]; then printf '  ok   allow  %s\n' "$1"; else printf '  FAIL allow  %s (rc=%s: %s)\n' "$1" "$rc" "$(head -c 120 /tmp/.gate-rm-glob-var.err.$$)"; fail=1; fi; }

echo "1. the incident and its relatives are refused"
block 'rm -rf /tmp/tmp.* 2>/dev/null; echo ok'
block 'rm -f "$TD"/health/*'
block 'rm -rf "$TD"'
block 'rm -rf ${SCRATCH:?}'
block 'rm -- $(ls -t /tmp | head -1)'
block 'rm -f /tmp/a?.log'
block 'rm -f /tmp/[ab].log'
block 'cd /tmp && rm -rf tmp.*'
block 'unlink "$f"'
block 'ls /tmp/x | xargs rm -f'
block 'find /tmp -name "tmp.*" -delete'
block 'find "$D" -type f -delete'
block 'find /tmp -maxdepth 1 -name "*.log" -exec rm {} +'
echo "2. through wrappers, shells, eval and substitutions"
block 'sudo rm -rf /var/tmp/*'
block 'timeout 10 rm -f /tmp/*.x'
block 'bash -c "rm -rf /tmp/tmp.*"'
block 'eval rm -rf "$X"'
block 'echo $(rm -f /tmp/*.y)'
block 'X=1 rm -f /tmp/*.z'
block 'true && rm -f /tmp/*.w'
echo "2b. quoting the guard cannot parse, and shells fed removal text"
block "echo \$'it\\'s'; rm -rf /tmp/tmp.*"
block "echo \$'it\\'s'; rm -f /tmp/literal-but-unparseable"
block "echo 'rm -rf /tmp/tmp.*' | bash"
block "printf 'rm -f %s\\n' /tmp/x/* | sh"
block "bash <<< 'rm -rf /tmp/tmp.*'"
block "python3 -c \"import glob,shutil; [shutil.rmtree(p) for p in glob.glob('/tmp/tmp.*')]\""
block "perl -e 'unlink glob \"/tmp/tmp.*\"'"
block "node -e \"require('fs').readdirSync('/tmp').filter(f=>f.startsWith('tmp.')).forEach(f=>require('fs').rmSync('/tmp/'+f,{recursive:true}))\""
allow "python3 -c \"import glob; print(glob.glob('/tmp/tmp.*'))\""
allow "echo \$'a\\tb'"
allow "echo 'hello' | bash"

echo "2d. a wrapper in front of the reader does not hide it"
block "echo 'rm -rf /tmp/tmp.*' | sudo bash"
block "echo 'rm -rf /tmp/tmp.*' | timeout 5 bash"
block "echo \"import os,glob; [os.remove(p) for p in glob.glob('/tmp/x*')]\" | sudo python3"
allow "cat /tmp/notes | sudo bash"

echo "2c. interpreters: heredoc, here-string, pipe, and a directory listing"
block "python3 - <<'EOF'
import glob, os
for p in glob.glob('/tmp/tmp.*'): os.remove(p)
EOF"
block "python3 -c \"import os; [os.remove(os.path.join('/tmp',f)) for f in os.listdir('/tmp')]\""
block "python3 <<< \"import shutil,glob; [shutil.rmtree(p) for p in glob.glob('/tmp/x*')]\""
block "echo \"import os; [os.unlink(f) for f in os.listdir('.')]\" | python3"
block "node - <<'EOF'
const fs=require('fs'); for (const f of fs.readdirSync('/tmp')) fs.rmSync('/tmp/'+f,{recursive:true});
EOF"
allow "python3 - <<'EOF'
import glob; print(glob.glob('/tmp/tmp.*'))
EOF"
allow "python3 -c \"import os; os.remove('/tmp/one-literal-file.txt')\""
allow "python3 - <<'EOF'
import shutil, glob
for p in glob.glob('/tmp/in/*.csv'): shutil.copy(p, '/tmp/out/')
print('copied; nothing to remove')
EOF"

echo "3. literal paths and non-removals are allowed"
allow 'rm -f /tmp/tmp.KUTTl6QGHv/report.txt'
allow 'rm -rf /tmp/claude-1001/scratch/old-dir'
allow 'mv /tmp/tmp.abc /tmp/tmp.abc.moved-aside-2026-10-17'
allow 'ls /tmp/tmp.* | head'
allow 'find /tmp -name "tmp.*" -mmin +60'
allow 'grep -n "rm -rf \$TD" bin/tests/x.test.sh'
allow 'echo "do not rm -rf /tmp/*"'
allow 'git rm --cached path/to/file'
allow 'cat > /tmp/s.sh <<EOS
rm -rf "$TD"
EOS'
echo "4. a heredoc read by a shell IS scanned"
block 'bash <<EOS
rm -rf /tmp/tmp.*
EOS'
echo "5. message names the ruling and the alternative"
run 'rm -rf /tmp/tmp.*'; grep -q 'no-wildcard-rm ruling' /tmp/.gate-rm-glob-var.err.$$ && grep -q 'move it aside' /tmp/.gate-rm-glob-var.err.$$ \
  && echo "  ok   message names the ruling and mv-aside" || { echo "  FAIL message: $(cat /tmp/.gate-rm-glob-var.err.$$)"; fail=1; }
echo "6. fails open on malformed input"
printf 'not json' | bash "$G" >/dev/null 2>&1; [ $? = 0 ] && echo "  ok   malformed payload allowed" || { echo "  FAIL malformed payload blocked"; fail=1; }
mv /tmp/.gate-rm-glob-var.err.$$ /tmp/.gate-rm-glob-var.err.$$.done 2>/dev/null
[ "$fail" = 0 ] && echo "gate-rm-glob-var.test: PASS" || { echo "gate-rm-glob-var.test: FAIL"; exit 1; }
