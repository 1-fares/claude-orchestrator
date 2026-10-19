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
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'commit message'; then
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
  git add -A && git commit -q -m "a resource id, already committed"
) >/dev/null 2>&1

out="$(cd "$tree_repo" && PRIVACY_DENY_FILE="$NO_DENY" bash bin/privacy-scan.sh --tree 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'i-0123456789abcdef0'; then
  echo "  ok       PLANTED POSITIVE: --tree finds data that is already committed"
else
  echo "  FAIL     --tree missed an already-committed resource id (exit $rc) -- $out"
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
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^  f.sh:'; then
  echo "  ok       CONTROL: a real --- / +++ pair still attributes to its file"
else
  echo "  FAIL     a real header pair stopped attributing (exit $rc) -- $out"
  fail=$((fail + 1))
fi

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

if [ "$fail" -eq 0 ]; then
  echo "RESULT status=ok key=privacy-scan failed=0"
else
  echo "RESULT status=red key=privacy-scan failed=$fail"
fi
exit $((fail > 0))
