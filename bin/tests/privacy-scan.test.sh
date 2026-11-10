#!/usr/bin/env bash
# privacy-scan.test.sh — the verdict table for bin/privacy-scan.sh.
#
# Written after the 2026-10-19 audit, which found that the gate had passed a
# private deployment's own directory and install names into the public history
# of this repo for five months. The scanner had no pattern for a cloud resource
# id, a provider key, a private key block or a real chat id, it allowlisted the
# Teams id suffixes outright, and it could only ever see ADDED DIFF LINES, so
# nothing already committed was in its reach.
#
# Every PLANTED POSITIVE below fails on the pre-audit scanner. The CONTROL
# cases are the placeholders and the documented false positives that must keep
# passing, because a gate that cries on its own documentation gets muted.
#
# Scratch lives at one LITERAL path, removed at entry and at exit. No rm of a
# computed path: a deletion whose target is a variable is the shape that takes
# a wrong directory with it when the variable is empty.
#
# EVERY FIXTURE BELOW IS INVENTED. An earlier draft of this file carried the
# real instance, security-group and chat ids from the audit that prompted it,
# which would have published them in a test for the gate that exists to stop
# exactly that. Use documented-example values (RFC 5737 addresses, AWS's own
# AKIAIOSFODNN7EXAMPLE) or obvious nonsense, never a value copied from a live
# system.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCAN="$repo/bin/privacy-scan.sh"
SCRATCH=/tmp/privacy-scan-test
rm -rf /tmp/privacy-scan-test
mkdir -p /tmp/privacy-scan-test
trap 'rm -rf /tmp/privacy-scan-test' EXIT
DENY="$SCRATCH/deny"
NO_DENY="$SCRATCH/deny-absent"
fail=0

# A one-line unified diff adding $1 to a file ($2, default some/file.sh).
# The --- / +++ PAIR IS DELIBERATE: a bare +++ is not a header any more, since
# an added line can forge one, so a fixture without the pair would not test
# what `git show` actually produces.
diff_adding() {
  local f="${2:-some/file.sh}"
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n+%s\n' "$f" "$f" "$f" "$f" "$1"
}

# block <name> <line> [deny_file]: the scanner must refuse it (exit 1).
block() {
  local name="$1" line="$2" deny="${3:-$NO_DENY}" out rc
  out="$(diff_adding "$line" | PRIVACY_DENY_FILE="$deny" bash "$SCAN" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "  ok       PLANTED POSITIVE blocked: $name"
  else
    echo "  FAIL     $name passed (exit $rc) -- $out"
    fail=$((fail + 1))
  fi
}

# pass <name> <line> [deny_file]: the scanner must allow it (exit 0).
pass() {
  local name="$1" line="$2" deny="${3:-$NO_DENY}" out rc
  out="$(diff_adding "$line" | PRIVACY_DENY_FILE="$deny" bash "$SCAN" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ok       CONTROL passed: $name"
  else
    echo "  FAIL     $name was blocked -- $out"
    fail=$((fail + 1))
  fi
}

echo "privacy-scan verdict table"

# --- what the gate already caught, and must keep catching -------------------
block "real home path"            'cd /home/someone/projects'
block "real email address"        'contact: person@realcompany.de'
block "ntfy topic"                'NTFY_URL=https://ntfy.sh/orch-7f3a9b2c'
block "api key assignment"        'api_key = "k93jf0wk20fj20fj"'
block "64-hex blob"               'KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
block "non-loopback IP"           'ssh 203.0.113.7'

# --- the classes the audit found missing ------------------------------------
block "EC2 instance id"           'TARGET=i-0123456789abcdef0'
block "security group id"         'aws ec2 describe --group-id sg-0fedcba987654321f'
block "security group RULE id"    'revoke sgr-0abcdef123456789a'
block "vpc id"                    'vpc_id = vpc-0a1b2c3d4e5f60718'
block "subnet id"                 'subnet-0a1b2c3d4e5f60718'
block "account id inside an ARN"  'role: arn:aws:iam::123456789012:role/thing'
block "AWS access key id"         'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE'
block "temporary access key id"   'ASIAIOSFODNN7EXAMPLE'
block "GitHub PAT value"          'GH_TOKEN=ghp_0123456789abcdefghijABCDEFGHIJ'
block "GitHub fine-grained PAT"   'github_pat_11ABCDEFG0abcdefghij_KLMNOPQRST'
block "Slack bot token"           'xoxb-123456789012-abcdefghijkl'
block "private key header"        '-----BEGIN OPENSSH PRIVATE KEY-----'
block "real Teams channel id"     'channel: 19:Q0hBTk5FTElERk9SVEVTVElOR09OTFlOT1RSRUFM@thread.tacv2'
block "real Teams chat id"        'chat: 19:0f1e2d3c4b5a69788796a5b4c3d2e1f0@thread.v2'

# --- controls: the placeholders this repo documents -------------------------
pass  "home placeholder"          'see /home/user/projects for the layout'
pass  "example.com address"       'export OPERATOR_EMAIL=user@example.com'
pass  "reserved .invalid domain"  'mail: someone@host.invalid'
pass  "noreply identity"          'author 44028238+1-fares@users.noreply.github.com'
pass  "angle-bracket ntfy topic"  'NTFY_URL=https://ntfy.sh/orch-<your-handle>-<random>'
pass  "documented ntfy example"   'e.g. https://ntfy.sh/orch-example'
pass  "ntfy docs link"            'format at https://docs.ntfy.sh/publish/'
pass  "loopback address"          'bind 127.0.0.1 only'
pass  "wildcard bind"             'listen on 0.0.0.0'
pass  "40-hex git sha"            'z40=0000000000000000000000000000000000000000'
pass  "placeholder chat id"       'chat 19:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@thread.v2'
pass  "placeholder channel id"    'channel 19:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb@thread.tacv2'
pass  "angle-bracket chat id"     'use 19:<id>@thread.v2 for a group chat'
pass  "token from a file"         'token = token_file'
pass  "python type annotation"    '    token: Optional[str] = None'
pass  "documented app path"       'ORCH_HOME=$HOME/projects/app'

# --- the deny file ----------------------------------------------------------
echo "deny file"
printf '%s\n' '# the deployment this engine is run for' 'acme-payroll' 'acmecorp' > "$DENY"
block "deny-list literal"         'source "$repo/acmecorp/gate.conf"'          "$DENY"
block "deny-list second entry"    'ORCH_HOME=$HOME/projects/acme-payroll'      "$DENY"
pass  "line matching no entry"    'ORCH_HOME=$HOME/projects/app'               "$DENY"

printf '%s\n' '# comments and blanks only' '' > "$SCRATCH/deny-comments"
pass  "comment-only deny file"    'source "$repo/acmecorp/gate.conf"' "$SCRATCH/deny-comments"
pass  "absent deny file"          'source "$repo/acmecorp/gate.conf"' "$NO_DENY"

# --- commit messages, which the gate never read until 2026-10-19 ------------
echo "commit messages"
show_shaped() {
  printf 'commit 0123456789abcdef0123456789abcdef01234567\nAuthor: x <x@example.com>\n\n    %s\n\ndiff --git a/f.sh b/f.sh\n--- a/f.sh\n+++ b/f.sh\n+echo hello\n' "$1"
}
out="$(show_shaped 'engine: upstreamed from the acmecorp fork' | PRIVACY_DENY_FILE="$DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'commit message' <<<"$out"; then
  echo "  ok       PLANTED POSITIVE: a deny-list name in a commit message is blocked"
else
  echo "  FAIL     a commit message carrying a private name passed (exit $rc) -- $out"
  fail=$((fail + 1))
fi

out="$(show_shaped 'fix: set api_key = k93jf0wk20fj20fj for the probe' | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  echo "  ok       PLANTED POSITIVE: a secret in a commit message is blocked"
else
  echo "  FAIL     a secret in a commit message passed (exit $rc) -- $out"
  fail=$((fail + 1))
fi

out="$(show_shaped 'engine: an ordinary message' | PRIVACY_DENY_FILE="$DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok       CONTROL: an ordinary commit message passes"
else
  echo "  FAIL     an ordinary commit message was blocked -- $out"
  fail=$((fail + 1))
fi

# An UNCHANGED context line is not being added, so it is not this gate's
# business, and a four-space-indented context line must not read as a message.
out="$(printf 'diff --git a/f.sh b/f.sh\n--- a/f.sh\n+++ b/f.sh\n@@ -1,2 +1,2 @@\n     api_key = "k93jf0wk20fj20fj"\n+echo hello\n' | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok       CONTROL: an indented context line is not read as a commit message"
else
  echo "  FAIL     an unchanged context line was blocked -- $out"
  fail=$((fail + 1))
fi

# --- --tree mode: what a diff can never show --------------------------------
echo "tree mode"
tree_repo="$SCRATCH/treerepo"
mkdir -p "$tree_repo/bin"
cp "$SCAN" "$tree_repo/bin/privacy-scan.sh"
(
  cd "$tree_repo"
  git init -q .
  git config user.email noreply@example.com
  git config user.name tester
  printf 'TARGET=i-0123456789abcdef0\n' > committed.sh
  : > sg-0fedcba987654321f.txt
  git add -A && git commit -q -m "a resource id, already committed"
) >/dev/null 2>&1

out="$(cd "$tree_repo" && PRIVACY_DENY_FILE="$NO_DENY" bash bin/privacy-scan.sh --tree 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'i-0123456789abcdef0' <<<"$out"; then
  echo "  ok       PLANTED POSITIVE: --tree finds data that is already committed"
else
  echo "  FAIL     --tree missed an already-committed resource id (exit $rc) -- $out"
  fail=$((fail + 1))
fi
# An empty file has no line for git grep to print; its name must still be read.
if [ "$rc" -eq 1 ] && grep -q 'sg-0fedcba987654321f' <<<"$out"; then
  echo "  ok       PLANTED POSITIVE: --tree reads the name of an empty tracked file"
else
  echo "  FAIL     --tree missed a private-shaped name on an empty tracked file (exit $rc) -- $out"
  fail=$((fail + 1))
fi

out="$(printf '' | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok       CONTROL: an empty diff passes"
else
  echo "  FAIL     an empty diff was blocked (exit $rc) -- $out"
  fail=$((fail + 1))
fi

out="$(PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" --nonsense </dev/null 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  echo "  ok       CONTROL: an unknown argument is a usage error, not a silent pass"
else
  echo "  FAIL     unknown argument gave exit $rc, expected 2 -- $out"
  fail=$((fail + 1))
fi

# --- the fixture-file exemption must stay one file wide ---------------------
echo "fixture exemption"
out="$(diff_adding 'TARGET=i-0123456789abcdef0' 'bin/tests/privacy-scan.test.sh' | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok       CONTROL: a fixture in this very file is exempt, so the gate is testable"
else
  echo "  FAIL     the fixture file is not exempt, the table cannot be committed -- $out"
  fail=$((fail + 1))
fi

out="$(diff_adding 'TARGET=i-0123456789abcdef0' 'bin/tests/other.test.sh' | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  echo "  ok       PLANTED POSITIVE: the exemption does not extend to another test file"
else
  echo "  FAIL     the exemption leaked to another path (exit $rc) -- $out"
  fail=$((fail + 1))
fi

out="$(diff_adding 'TARGET=i-0123456789abcdef0' 'bin/tests/privacy-scan.test.sh.bak' | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  echo "  ok       PLANTED POSITIVE: a path that merely starts with the fixture name is not exempt"
else
  echo "  FAIL     a prefix of the fixture path was exempted (exit $rc) -- $out"
  fail=$((fail + 1))
fi

# --- the value test: coverage must not shrink -------------------------------
# The discriminator exists so a keyword followed by ordinary English is not
# refused. These pin the line between that and a credential, after the first
# version of it gave back two shapes the previous scanner caught.
echo "value discriminator"
block "long value, no digit, trailing prose"  'secret: abcdefghijklmnop and then prose'
block "13-char value with prose after it"     'password: hunterrsecret see the docs'
block "value running to end of line"          'token: abcdefghij'
block "value containing a digit"              'api_key = k93jf0wk20fj20fj'
block "hyphenated value to end of line"       'token: decisions-status-line'
pass  "keyword then an ordinary word"         'a secret: something ordinary in prose'
pass  "keyword, hyphenated phrase, more prose" '# prose token: decisions-status-line and orphan'
pass  "keyword, 9-letter word, more prose"     'the bearer: whosoever carries the message onward'
block "hyphen first, then a 12+ run, prose"    'secret: abc-defghijklmnopqrs and more words'
block "keyword, password to end of line"       'password: correcthorsebattery'

# --- the forged file header -------------------------------------------------
# A '+++ b/<path>' line can arrive as added CONTENT. Paired with the fixture
# exemption that turned misattribution into a bypass: an AKIA key passed by
# naming the exempt path (measured 2026-10-19).
echo "forged file header"
out="$(printf 'diff --git a/secrets.sh b/secrets.sh\n--- a/secrets.sh\n+++ b/secrets.sh\n+++ b/bin/tests/privacy-scan.test.sh\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n' | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  echo "  ok       PLANTED POSITIVE: a forged +++ line cannot borrow the exemption"
else
  echo "  FAIL     the gate was bypassed by a forged file header (exit $rc) -- $out"
  fail=$((fail + 1))
fi

out="$(printf 'diff --git a/f.sh b/f.sh\n--- a/f.sh\n+++ b/f.sh\n+TARGET=i-0123456789abcdef0\n' | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q '^  f.sh:' <<<"$out"; then
  echo "  ok       CONTROL: a real --- / +++ pair still attributes to its file"
else
  echo "  FAIL     a real header pair stopped attributing (exit $rc) -- $out"
  fail=$((fail + 1))
fi

# --- parser differentials: shape must never outrank position ----------------
# Each of these forged a file header out of content and borrowed the fixture
# exemption. All measured on 2026-10-19, each against the fix that preceded it.
echo "parser differentials"
probe() { # probe <name> <expected_exit> <diff text>
  local name="$1" want="$2" text="$3" out rc
  out="$(printf '%b' "$text" | PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    echo "  ok       $name"
  else
    echo "  FAIL     $name: exit $rc, expected $want -- $out"
    fail=$((fail + 1))
  fi
}

probe "a deletion and an addition forging a pair inside a hunk" 1 \
  'diff --git a/s.sh b/s.sh\n--- a/s.sh\n+++ b/s.sh\n@@ -1,3 +1,3 @@\n--- a/x\n+++ b/bin/tests/privacy-scan.test.sh\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'

probe "a lone +++ line with no hunk header at all" 1 \
  'diff --git a/s.sh b/s.sh\n--- a/s.sh\n+++ b/s.sh\n+++ b/bin/tests/privacy-scan.test.sh\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'

probe "a combined merge diff, whose @@@ counts are not read" 1 \
  'diff --combined s.sh\n--- a/s.sh\n+++ b/s.sh\n@@@ -1,2 -1,2 +1,3 @@@\n--- a/x\n+++ b/bin/tests/privacy-scan.test.sh\n++AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'

probe "a path whose first space truncated it to the exempt name" 1 \
  'diff --git a/x b/x\n--- a/bin/tests/privacy-scan.test.sh extra\n+++ b/bin/tests/privacy-scan.test.sh extra\n@@ -1 +1 @@\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'

probe "a path matching the exempt name only as a regex" 1 \
  'diff --git a/x b/x\n--- a/bin/tests/privacy-scanXtestXsh\n+++ b/bin/tests/privacy-scanXtestXsh\n@@ -1 +1 @@\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'

probe "CONTROL: the genuine fixture file is still exempt" 0 \
  'diff --git a/bin/tests/privacy-scan.test.sh b/bin/tests/privacy-scan.test.sh\n--- a/bin/tests/privacy-scan.test.sh\n+++ b/bin/tests/privacy-scan.test.sh\n@@ -1 +1 @@\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'

probe "CONTROL: a plain hunk still attributes and still blocks" 1 \
  'diff --git a/f.sh b/f.sh\n--- a/f.sh\n+++ b/f.sh\n@@ -1 +1 @@\n+TARGET=i-0123456789abcdef0\n'

probe "CONTROL: a deleted line is not scanned, only added ones" 0 \
  'diff --git a/f.sh b/f.sh\n--- a/f.sh\n+++ b/f.sh\n@@ -1,2 +1,1 @@\n-AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n+clean\n'

# --- the deny file must fail closed, not open -------------------------------
echo "deny file failure modes"
printf 'acmecorp\n' > "$SCRATCH/deny-unreadable"
chmod 000 "$SCRATCH/deny-unreadable"
out="$(printf '+++ b/f.sh\n+source "$repo/acmecorp/x.conf"\n' | PRIVACY_DENY_FILE="$SCRATCH/deny-unreadable" bash "$SCAN" 2>&1)"; rc=$?
chmod 644 "$SCRATCH/deny-unreadable"
if [ "$rc" -eq 2 ]; then
  echo "  ok       PLANTED POSITIVE: an unreadable deny file stops the scan, it does not disable it"
else
  echo "  FAIL     an unreadable deny file passed silently (exit $rc) -- $out"
  fail=$((fail + 1))
fi

# --- this repo's own tree must stay clean -----------------------------------
echo "self check"
out="$(cd "$repo" && bash bin/privacy-scan.sh --tree 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok       CONTROL: this repo's tracked tree is clean"
else
  echo "  FAIL     this repo's own tree is flagged -- $out"
  fail=$((fail + 1))
fi

# --- file names: a header-only change carries a name and no added line ----------
# A path used to be scanned only as the prefix of an added line, so a pure rename, an empty new file
# and a binary file put their names into a patch unscanned.
echo "file names"
probe "PLANTED: a pure rename to a private-shaped name" 1 \
  'diff --git a/notes/x.txt b/notes/i-0123456789abcdef0.txt\nsimilarity index 100%%\nrename from notes/x.txt\nrename to notes/i-0123456789abcdef0.txt\n'
probe "PLANTED: an empty new file with a private-shaped name" 1 \
  'diff --git a/notes/i-0123456789abcdef0.txt b/notes/i-0123456789abcdef0.txt\nnew file mode 100644\nindex 0000000..e69de29\n'
probe "PLANTED: a binary new file with a private-shaped name" 1 \
  'diff --git a/img/i-0123456789abcdef0.png b/img/i-0123456789abcdef0.png\nnew file mode 100644\nindex 0000000..1234567\nBinary files /dev/null and b/img/i-0123456789abcdef0.png differ\n'
probe "CONTROL: a generic rename passes" 0 \
  'diff --git a/notes/x.txt b/notes/y.txt\nsimilarity index 100%%\nrename from notes/x.txt\nrename to notes/y.txt\n'
probe "CONTROL: a removed line reading like a rename header is content, not a name" 0 \
  'diff --git a/s.sh b/s.sh\n--- a/s.sh\n+++ b/s.sh\n@@ -1,2 +1,2 @@\n a\n-rename to notes/i-0123456789abcdef0.txt\n+b\n'

# --- a bad deny line must stop the scan, not switch the list off -----------------
# The lines were joined into one expression and matched with `grep ... || true`, so one line that
# did not compile made grep exit 2, read as "no hit": the whole list was off.
echo "deny line validation"
printf 'acmecorp\nwidget(co\n' > "$SCRATCH/deny-badline"
out="$(diff_adding 'source "$repo/acmecorp/x.conf"' | PRIVACY_DENY_FILE="$SCRATCH/deny-badline" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'line 2 ' <<<"$out"; then
  echo "  ok       PLANTED POSITIVE: a deny line that does not compile stops the scan and is named"
else
  echo "  FAIL     a bad deny line did not stop the scan (exit $rc) -- $out"
  fail=$((fail + 1))
fi
printf -- '--acme-secret-name\n' > "$SCRATCH/deny-dash"
block "a deny line that starts with a dash" 'x --acme-secret-name y' "$SCRATCH/deny-dash"

# --- b/ is a diff prefix only in a prefixed diff ---------------------------------
echo "diff prefixes"
probe "PLANTED: --no-prefix diff of a file under b/ is not the fixture" 1 \
  'diff --git b/bin/tests/privacy-scan.test.sh b/bin/tests/privacy-scan.test.sh\nnew file mode 100644\n--- /dev/null\n+++ b/bin/tests/privacy-scan.test.sh\n@@ -0,0 +1 @@\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'
probe "PLANTED: --no-prefix change to a file under b/ is not the fixture" 1 \
  'diff --git b/bin/tests/privacy-scan.test.sh b/bin/tests/privacy-scan.test.sh\n--- b/bin/tests/privacy-scan.test.sh\n+++ b/bin/tests/privacy-scan.test.sh\n@@ -1 +1 @@\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'
probe "CONTROL: a new fixture file in a prefixed diff is still exempt" 0 \
  'diff --git a/bin/tests/privacy-scan.test.sh b/bin/tests/privacy-scan.test.sh\nnew file mode 100644\n--- /dev/null\n+++ b/bin/tests/privacy-scan.test.sh\n@@ -0,0 +1 @@\n+AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'

# --- --tree: a file named like the fixture plus ":1:x" -------------------------
echo "tree mode, colon in a name"
tree2="$SCRATCH/treerepo2"
mkdir -p "$tree2/bin/tests"
cp "$SCAN" "$tree2/bin/privacy-scan.sh"
(
  cd "$tree2"
  git init -q .
  git config user.email noreply@example.com
  git config user.name tester
  printf 'TARGET=i-0123456789abcdef0\n' > 'bin/tests/privacy-scan.test.sh:1:x'
  git add -A && git commit -q -m "a colon in a file name"
) >/dev/null 2>&1
out="$(cd "$tree2" && PRIVACY_DENY_FILE="$NO_DENY" bash bin/privacy-scan.sh --tree 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'i-0123456789abcdef0' <<<"$out"; then
  echo "  ok       PLANTED POSITIVE: a name with the fixture path before a colon is not exempt"
else
  echo "  FAIL     a colon-split name borrowed the fixture exemption (exit $rc) -- $out"
  fail=$((fail + 1))
fi

# --- allowlist anchoring: a placeholder excuses only the part it stands for ------
# The <angle-bracket> entry was unanchored, so a real topic or chat id with a
# marker appended passed; `^noreply@` allowed a noreply address at any domain.
echo "allowlist anchoring"
block "a marker appended to a real ntfy topic"   'NTFY_URL=https://ntfy.sh/f7a3realtopic<x>'
block "a marker appended to a real chat id"      'channel: 19:Q0hBTk5FTElERk9SVEVT<x>@thread.tacv2'
block "a noreply address at a private domain"    'reply-to: noreply@acme-corp.ch'
pass  "an ntfy topic that is one marker"         'POST to https://ntfy.sh/<topic>'
pass  "a chat id that is one marker"             'chat 19:<chat-id>@thread.v2'
pass  "GitHub's web-UI committer address"        'committer GitHub <noreply@github.com>'
block "a noreply address under a lookalike domain" 'noreply@github.com.acme-corp.ch'

# --- a byte that is not UTF-8 must not hide its line -------------------------------
# GNU grep withheld a matching line holding such a byte ("binary file matches").
echo "non-UTF-8 bytes"
out="$(diff_adding "$(printf 'caf\351 AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE')" | LC_ALL=C.UTF-8 PRIVACY_DENY_FILE="$NO_DENY" bash "$SCAN" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'AKIAIOSFODNN7EXAMPLE' <<<"$out"; then
  echo "  ok       PLANTED POSITIVE: a key on a line with a Latin-1 byte is blocked under a UTF-8 locale"
else
  echo "  FAIL     a key next to a non-UTF-8 byte passed (exit $rc) -- $out"
  fail=$((fail + 1))
fi

# --- the public identity list: one line, one whole-value pattern -------------------
# Joined with |, a line with an unmatched ) broke the -x anchoring of the next one.
echo "public identity list"
printf 'qq)\njane\\.roe@acme-corp\\.ch\n' > "$SCRATCH/pub-paren"
out="$(printf 'abc1234 author-email:qqxyz@acme-corp.ch\n' | PRIVACY_DENY_FILE="$NO_DENY" PRIVACY_PUBLIC_IDENTITIES="$SCRATCH/pub-paren" bash "$SCAN" --identities 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  echo "  ok       PLANTED POSITIVE: a stray ) in one line does not exempt every value starting with it"
else
  echo "  FAIL     a private address passed by prefix of a public identity line (exit $rc) -- $out"
  fail=$((fail + 1))
fi
out="$(printf 'abc1234 author-email:jane.roe@acme-corp.ch\n' | PRIVACY_DENY_FILE="$NO_DENY" PRIVACY_PUBLIC_IDENTITIES="$SCRATCH/pub-paren" bash "$SCAN" --identities 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "  ok       CONTROL: the line after it is still a whole-value pattern of its own" \
  || { echo "  FAIL     a listed identity was blocked (exit $rc) -- $out"; fail=$((fail + 1)); }

# --- bin/hooks/pre-push: identity, per-remote selection, a ref that moved --------
# A throwaway clone with two bare remotes; the hook is run directly with the
# stdin git would give it. Nothing leaves the scratch directory.
echo "pre-push"
pp="$SCRATCH/pp"
mkdir -p "$pp/bin/hooks"
cp "$SCAN" "$pp/bin/privacy-scan.sh"
cp "$repo/bin/hooks/pre-push" "$pp/bin/hooks/pre-push"
z40=0000000000000000000000000000000000000000
ppgit() { git -C "$pp" -c user.name=tester -c user.email=noreply@example.com "$@"; }
pphook() { # pphook <name> <expected_exit> <remote> <stdin line>
  local out rc
  out="$(cd "$pp" && printf '%s\n' "$4" | PRIVACY_DENY_FILE="$NO_DENY" PRIVACY_PUBLIC_IDENTITIES="${PP_PUB:-$SCRATCH/pub-absent}" bash bin/hooks/pre-push "$3" "$SCRATCH/$3.git" 2>&1)"; rc=$?
  if [ "$rc" -eq "$2" ]; then echo "  ok       $1"; else echo "  FAIL     $1: exit $rc, expected $2 -- $out"; fail=$((fail + 1)); fi
}
(
  git init -q --bare "$SCRATCH/pub.git" && git init -q --bare "$SCRATCH/priv.git"
  ppgit init -q -b master . && ppgit remote add pub "$SCRATCH/pub.git" && ppgit remote add priv "$SCRATCH/priv.git"
  echo base > "$pp/base.txt" && ppgit add -A && ppgit commit -q -m base
  ppgit push -q pub master && ppgit push -q priv master
) >/dev/null 2>&1
base="$(ppgit rev-parse HEAD)"

# Identity: content and message clean, the author and committer are not.
(
  ppgit checkout -q -b ident "$base"
  echo one > "$pp/one.txt" && git -C "$pp" add one.txt
  GIT_AUTHOR_NAME='Jane Roe' GIT_AUTHOR_EMAIL='jane.roe@acme-corp.ch' \
  GIT_COMMITTER_NAME='Jane Roe' GIT_COMMITTER_EMAIL='jane.roe@acme-corp.ch' git -C "$pp" commit -q -m clean
) >/dev/null 2>&1
ident="$(ppgit rev-parse ident)"
pphook "PLANTED: a private author and committer address is refused" 1 pub "refs/heads/ident $ident refs/heads/ident $z40"
printf '# public identities\nJane Roe\njane\\.roe@acme-corp\\.ch\n' > "$SCRATCH/pub-ids"
PP_PUB="$SCRATCH/pub-ids" pphook "CONTROL: an identity listed as public passes" 0 pub "refs/heads/ident $ident refs/heads/ident $z40"
printf 'Jane Roe\n' > "$SCRATCH/pub-name-only"
PP_PUB="$SCRATCH/pub-name-only" pphook "PLANTED: listing the name does not exempt the address" 1 pub "refs/heads/ident $ident refs/heads/ident $z40"
printf 'acme-corp\n' > "$SCRATCH/deny-acme"
out="$(cd "$pp" && printf 'refs/heads/ident %s refs/heads/ident %s\n' "$ident" "$z40" | PRIVACY_DENY_FILE="$SCRATCH/deny-acme" PRIVACY_PUBLIC_IDENTITIES="$SCRATCH/pub-name-only" bash bin/hooks/pre-push pub "$SCRATCH/pub.git" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'author-email: acme-corp (deny list)' <<<"$out"; then
  echo "  ok       PLANTED: the deny list applies to identities"
else
  echo "  FAIL     the deny list missed an identity (exit $rc) -- $out"
  fail=$((fail + 1))
fi

# Selection: a commit already on remote priv is still outgoing to remote pub.
(
  ppgit checkout -q -b leak "$base"
  printf 'TARGET=i-0123456789abcdef0\n' > "$pp/leak.sh" && ppgit add -A && ppgit commit -q -m leak
  ppgit push -q priv leak
) >/dev/null 2>&1
leak="$(ppgit rev-parse leak)"
pphook "PLANTED: a new branch already on another remote is scanned" 1 pub "refs/heads/leak $leak refs/heads/leak $z40"
pphook "PLANTED: an update already on another remote is scanned" 1 pub "refs/heads/leak $leak refs/heads/master $base"
pphook "CONTROL: nothing is outgoing to the remote that has it" 0 priv "refs/heads/leak $leak refs/heads/leak $leak"

# Moved: the ref no longer points at what was scanned.
(
  ppgit checkout -q -b moving "$base"
  echo a > "$pp/a.txt" && ppgit add -A && ppgit commit -q -m a
) >/dev/null 2>&1
scanned="$(ppgit rev-parse moving)"
( echo b > "$pp/b.txt" && ppgit add -A && ppgit commit -q -m b ) >/dev/null 2>&1
pphook "PLANTED: a ref that moved after git listed it is refused" 1 pub "refs/heads/moving $scanned refs/heads/moving $z40"
pphook "CONTROL: an explicit-sha push sends what was scanned" 0 pub "$scanned $scanned refs/heads/moving $z40"
pphook "CONTROL: a ref that did not move passes" 0 pub "refs/heads/moving $(ppgit rev-parse moving) refs/heads/moving $z40"
ppgit tag -a -m t v1 "$base" >/dev/null 2>&1
pphook "CONTROL: an annotated tag is not read as moved" 0 pub "refs/tags/v1 $(ppgit rev-parse v1) refs/tags/v1 $z40"
pphook "CONTROL: an unknown sha fails closed" 1 pub "refs/heads/x 1111111111111111111111111111111111111111 refs/heads/x $z40"

# pphook2 <name> <expected_exit> <arg1> <arg2> <stdin line> [text the output must hold]
pphook2() {
  local out rc
  out="$(cd "$pp" && printf '%s\n' "$5" | PRIVACY_DENY_FILE="$NO_DENY" PRIVACY_PUBLIC_IDENTITIES="$SCRATCH/pub-absent" bash bin/hooks/pre-push "$3" "$4" 2>&1)"; rc=$?
  if [ "$rc" -eq "$2" ] && { [ -z "${6:-}" ] || grep -qF -- "$6" <<<"$out"; }; then echo "  ok       $1"
  else echo "  FAIL     $1: exit $rc, expected $2${6:+ and '$6'} -- $out"; fail=$((fail + 1)); fi
}

# Annotated tags: the tag object is sent too, and rev-list peels it away.
ppgit tag -a -m 'release AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE' t-msg "$base" >/dev/null 2>&1
pphook "PLANTED: a key in an annotated tag message is refused" 1 pub "refs/tags/t-msg $(ppgit rev-parse t-msg) refs/tags/t-msg $z40"
git -C "$pp" -c user.name='Jane Roe' -c user.email='jane.roe@acme-corp.ch' tag -a -m clean t-who "$base" >/dev/null 2>&1
pphook "PLANTED: a private tagger address is refused" 1 pub "refs/tags/t-who $(ppgit rev-parse t-who) refs/tags/t-who $z40"
ppgit tag -a -m 'inner AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE' t-inner "$base" >/dev/null 2>&1
ppgit tag -a -m outer t-outer t-inner >/dev/null 2>&1
pphook "PLANTED: a key in a nested tag under a clean one is refused" 1 pub "refs/tags/t-outer $(ppgit rev-parse t-outer) refs/tags/t-outer $z40"
ppgit push -q pub t-inner >/dev/null 2>&1
pphook "CONTROL: a tag object the destination already has is not sent, so not scanned" 0 pub "refs/tags/t-outer $(ppgit rev-parse t-outer) refs/tags/t-outer $z40"

# Content hidden by git settings: git show must always print a prefixed text diff and the message.
(
  ppgit checkout -q -b attr "$base"
  printf 'notes.txt -diff\n' > "$pp/.gitattributes"; printf 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n' > "$pp/notes.txt"
  ppgit add -A && ppgit commit -q -m attr
) >/dev/null 2>&1
pphook "PLANTED: a -diff attribute does not print the content away as binary" 1 pub "refs/heads/attr $(ppgit rev-parse attr) refs/heads/attr $z40"
(
  ppgit checkout -q -b noprefix "$base"
  mkdir -p "$pp/a" && seq 1 30 > "$pp/a/foo" && ppgit add -A && ppgit commit -q -m foo
  mkdir -p "$pp/b/bin/tests" && ppgit mv a/foo b/bin/tests/privacy-scan.test.sh
  printf 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n' >> "$pp/b/bin/tests/privacy-scan.test.sh"
  ppgit add -A && ppgit commit -q -m rename
) >/dev/null 2>&1
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true \
  pphook "PLANTED: diff.noprefix does not make a rename into b/ the exempt fixture" 1 pub "refs/heads/noprefix $(ppgit rev-parse noprefix) refs/heads/noprefix $z40"
(
  ppgit checkout -q -b msgkey "$base"
  echo m > "$pp/m.txt" && ppgit add -A && ppgit commit -q -m 'probe AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE'
  ppgit checkout -q -b colorkey "$base"
  printf 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n' > "$pp/c.txt" && ppgit add -A && ppgit commit -q -m color
) >/dev/null 2>&1
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=format.pretty GIT_CONFIG_VALUE_0=oneline \
  pphook "PLANTED: format.pretty=oneline does not hide the message" 1 pub "refs/heads/msgkey $(ppgit rev-parse msgkey) refs/heads/msgkey $z40"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=i18n.logOutputEncoding GIT_CONFIG_VALUE_0=UTF-16 \
  pphook "PLANTED: a UTF-16 log output encoding does not hide the message" 1 pub "refs/heads/msgkey $(ppgit rev-parse msgkey) refs/heads/msgkey $z40"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=color.ui GIT_CONFIG_VALUE_0=always \
  pphook "PLANTED: color.ui=always does not hide added lines" 1 pub "refs/heads/colorkey $(ppgit rev-parse colorkey) refs/heads/colorkey $z40"

# Selection rests on what the DESTINATION has, not on remote-tracking refs.
(
  ppgit checkout -q -b stale "$base"
  printf 'TARGET=i-0123456789abcdef0\n' > "$pp/stale.sh" && ppgit add -A && ppgit commit -q -m stale
  ppgit update-ref refs/remotes/pub/stale HEAD   # a tracking ref the destination does not back
) >/dev/null 2>&1
pphook "PLANTED: a stale tracking ref does not hide a commit the destination lacks" 1 pub "refs/heads/stale $(ppgit rev-parse stale) refs/heads/stale $z40"
(
  ppgit checkout -q -b oldhit "$base"
  printf 'TARGET=i-0123456789abcdef0\n' > "$pp/old.sh" && ppgit add -A && ppgit commit -q -m oldhit
  ppgit push -q pub oldhit
  echo clean > "$pp/ontop.txt" && ppgit add -A && ppgit commit -q -m ontop
) >/dev/null 2>&1
pphook2 "CONTROL: a push to a bare URL skips what the destination already has" 0 "$SCRATCH/pub.git" "$SCRATCH/pub.git" \
  "refs/heads/oldhit $(ppgit rev-parse oldhit) refs/heads/ontop $z40"
pphook2 "PLANTED: a destination that cannot be listed refuses the push" 1 absent "$SCRATCH/absent.git" \
  "refs/heads/master $base refs/heads/master $z40" "cannot list the refs of the destination"

# config/privacy-known-history.txt: content skipped for a listed full id, identities still scanned.
mkdir -p "$pp/config"
(
  ppgit checkout -q -b known "$base"
  printf 'TARGET=i-0123456789abcdef0\n' > "$pp/known.sh" && ppgit add -A && ppgit commit -q -m known
) >/dev/null 2>&1
known="$(ppgit rev-parse known)"
printf '# reviewed\n%s  # a planted fixture\n' "$known" > "$pp/config/privacy-known-history.txt"
pphook "CONTROL: a listed commit's content is not scanned" 0 pub "refs/heads/known $known refs/heads/known $z40"
printf '%s\n' "$ident" > "$pp/config/privacy-known-history.txt"
pphook "CONTROL: a listed commit's author and committer still are" 1 pub "refs/heads/ident $ident refs/heads/ident $z40"
pphook "CONTROL: a commit not listed is scanned" 1 pub "refs/heads/known $known refs/heads/known $z40"
printf '%s\n' "${known:0:12}" > "$pp/config/privacy-known-history.txt"
pphook2 "PLANTED: an abbreviated id in the list refuses the push" 1 pub "$SCRATCH/pub.git" \
  "refs/heads/master $base refs/heads/master $z40" "not a full 40-character commit id"
: > "$pp/config/privacy-known-history.txt"

if [ "$fail" -eq 0 ]; then
  echo "RESULT status=ok key=privacy-scan failed=0"
else
  echo "RESULT status=red key=privacy-scan failed=$fail"
fi
exit $((fail > 0))
