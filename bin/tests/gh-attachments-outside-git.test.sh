#!/usr/bin/env bash
# gh-attachments-outside-git.test.sh: bin/gh-attachments.sh never writes inside a git work tree.
# The former fallbacks ($TEAM_DIR/attachments, then $PWD/gh-attachments) put ticket attachments, which
# are personal data, into whatever tree the script ran from. The default root is now
# $HOME/scratch/gh-attachments (dirs 700, files 600), and an output dir that resolves into a git
# repository is refused with exit 2 before any gh/curl call or write.
# Hermetic: a fake HOME, stub gh and curl that log their calls, throwaway git repos. Everything lives
# under one fixed scratch path, removed by literal path at the start and on exit, so do not run two
# copies of this test at once.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
G="${GH_ATTACHMENTS_UNDER_TEST:-$repo/bin/gh-attachments.sh}"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
[ -f "$G" ] || { echo "ABORT: no script at $G"; exit 2; }

rm -rf /tmp/orch-test-gh-attachments
mkdir /tmp/orch-test-gh-attachments || { echo "ABORT: cannot create the scratch dir"; exit 2; }
trap 'rm -rf /tmp/orch-test-gh-attachments' EXIT
T=/tmp/orch-test-gh-attachments
mkdir -p "$T/fakehome" "$T/bin" "$T/repo/sub" "$T/repo/.team-r1"
env -u GIT_DIR -u GIT_WORK_TREE git init -q "$T/repo" || { echo "ABORT: git init failed"; exit 2; }
printf '.team-r*/\n' > "$T/repo/.gitignore"
ln -s "$T/repo/sub" "$T/link"
CALLS="$T/calls.log"; : > "$CALLS"
# Stubs: gh returns one attachment url in the issue body and no comments; curl writes bytes to -o, prints 200.
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$CALLS"
case "\$1 \$2" in "auth token") echo tok ;; "api "*) case "\$*" in *comments*) : ;; *) echo '<img src="https://github.com/user-attachments/assets/abc123">' ;; esac ;; esac
EOF
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$CALLS"
out=""; while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && printf 'PNGDATA' > "\$out"; printf 200
EOF
chmod +x "$T/bin/gh" "$T/bin/curl"
run() {  # run <cwd> [VAR=val ...]: the script for o/r#7 from <cwd>, TEAM_DIR and GH_ATTACHMENTS_DIR unset unless given
  local cwd="$1"; shift
  (cd "$cwd" && env -u TEAM_DIR -u GH_ATTACHMENTS_DIR -u GH_ATTACHMENTS_RESOLVE_ONLY HOME="$T/fakehome" \
     PATH="$T/bin:$PATH" GH_ATTACHMENTS_TOKEN=tok "$@" bash "$G" o/r 7 2>&1)
}
_list() { find "$T/repo" -path "$T/repo/.git" -prune -o -print 2>/dev/null | sort; }
BASE="$(_list)"
nothing_in_repo() { [ "$(_list)" = "$BASE" ]; }
added() { comm -13 <(printf '%s\n' "$BASE") <(_list) | head -5; }

echo "== 1. a full run from a repo root writes nothing inside the repo"
out="$(run "$T/repo")"; rc=$?
[ "$rc" = 0 ] && ok "run succeeded (rc 0)" || no "run failed" "rc=$rc $out"
nothing_in_repo && ok "nothing created under the repo" || no "files created inside the repo" "$(added)"
[ -f "$T/fakehome/scratch/gh-attachments/o-r-7/01-abc123" ] && ok "the attachment landed in \$HOME/scratch/gh-attachments/o-r-7" \
  || no "attachment not in the default root" "$out"

echo "== 2. modes: dirs 700, file 600"
for p in "$T/fakehome/scratch/gh-attachments" "$T/fakehome/scratch/gh-attachments/o-r-7"; do
  m="$(stat -c %a "$p" 2>/dev/null)"; [ "$m" = 700 ] && ok "${p#"$T"/} is 700" || no "${p#"$T"/} mode" "$m"
done
m="$(stat -c %a "$T/fakehome/scratch/gh-attachments/o-r-7/01-abc123" 2>/dev/null)"
[ "$m" = 600 ] && ok "the downloaded file is 600" || no "file mode" "$m"

echo "== 3. resolution: the default root ignores PWD and TEAM_DIR"
out="$(run "$T" GH_ATTACHMENTS_RESOLVE_ONLY=1)"; rc=$?
[ "$rc" = 0 ] && grep -q "output dir $T/fakehome/scratch/gh-attachments/o-r-7$" <<<"$out" && ok "default: \$HOME/scratch/gh-attachments" \
  || no "default root" "rc=$rc $out"
out="$(run "$T/repo" TEAM_DIR="$T/repo/.team-r1" GH_ATTACHMENTS_RESOLVE_ONLY=1)"; rc=$?
[ "$rc" = 0 ] && grep -q "output dir $T/fakehome/scratch/gh-attachments/o-r-7$" <<<"$out" && ok "PWD = repo root and TEAM_DIR inside it: still outside git" \
  || no "PWD or TEAM_DIR changed the root" "rc=$rc $out"

echo "== 4. refusals: exit 2, no gh/curl call, nothing created"
for d in "$T/repo/att" "$T/repo/.team-r1/attachments" "$T/link/att" "att"; do
  : > "$CALLS"
  out="$(run "$T/repo" GH_ATTACHMENTS_DIR="$d")"; rc=$?
  label="$d"; [ "$d" = att ] && label="relative 'att' from the repo root"
  [ "$rc" = 2 ] && grep -q 'REFUSED' <<<"$out" && ok "refused: ${label#"$T"/}" || no "not refused: $label" "rc=$rc $out"
  [ ! -s "$CALLS" ] && ok "  no gh/curl call before the refusal" || no "  network calls made" "$(cat "$CALLS")"
done
git init -q --bare "$T/bare.git"; mkdir -p "$T/plain"
out="$(run "$T" GIT_DIR="$T/bare.git" GIT_WORK_TREE="$T/plain" GH_ATTACHMENTS_DIR="$T/repo/sub/att")"; rc=$?
[ "$rc" = 2 ] && [ ! -e "$T/repo/sub/att" ] && ok "an inherited GIT_DIR/GIT_WORK_TREE does not hide the repo" || no "GIT_DIR bypass" "rc=$rc $out"
out="$(run "$T" GH_ATTACHMENTS_DIR="$T/bare.git/att")"; rc=$?
[ "$rc" = 2 ] && [ ! -e "$T/bare.git/att" ] && ok "inside a bare repo: refused" || no "bare repo accepted" "rc=$rc $out"
ln -s "$T/repo/sub/notyet" "$T/dangling"
out="$(run "$T" GH_ATTACHMENTS_DIR="$T/dangling" GH_ATTACHMENTS_RESOLVE_ONLY=1)"; rc=$?
[ "$rc" = 2 ] && ok "a dangling symlink into a repo: refused" || no "dangling symlink resolved as safe" "rc=$rc $out"
nothing_in_repo && ok "after every refusal nothing exists under the repo" || no "a refused run created files" "$(added)"

echo "== 5. an explicit dir outside every git tree is honoured"
out="$(run "$T" GH_ATTACHMENTS_DIR="$T/elsewhere" GH_ATTACHMENTS_RESOLVE_ONLY=1)"; rc=$?
[ "$rc" = 0 ] && grep -q "output dir $T/elsewhere/o-r-7$" <<<"$out" && ok "GH_ATTACHMENTS_DIR outside git: used" || no "explicit outside dir" "rc=$rc $out"

echo "== 6. the janitor expires the same root"
# shellcheck disable=SC2016
want='${GH_ATTACHMENTS_DIR:-${HOME:-/nonexistent}/scratch/gh-attachments}'
grep -qF "attach_dir=\"$want\"" "$repo/bin/night-janitor.sh" && ! grep -q 'TEAM_DIR/attachments' "$repo/bin/night-janitor.sh" \
  && ok "night-janitor expires GH_ATTACHMENTS_DIR, default \$HOME/scratch/gh-attachments" || no "night-janitor attachments root"

echo
echo "gh-attachments-outside-git: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
