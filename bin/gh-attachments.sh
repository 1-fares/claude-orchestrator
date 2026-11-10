#!/usr/bin/env bash
# gh-attachments.sh -- download every image / video / file attachment from a GitHub
# issue or PR (body + all comments) using the gh token.
#
# WHY: a plain UNAUTHENTICATED curl to a github user-attachments URL returns 404,
# which was long MISread as "attachments need a browser login we do not have". They
# do not. The gh token downloads them (Authorization: token <gh token>). The
# full+json media type additionally rewrites image/video links into short-lived
# signed (jwt) URLs that download with NO auth header at all.
#
# Usage:
#   gh-attachments.sh <issue-or-pr-url>
#   gh-attachments.sh <owner>/<repo> <number>
#
# Output dir: ${GH_ATTACHMENTS_DIR:-$HOME/scratch/gh-attachments}/<owner>-<repo>-<num>/
# (dirs 700, files 600). Ticket attachments are personal data and never go inside a git
# work tree: the former fallbacks ($TEAM_DIR/attachments, then ./gh-attachments) put them
# into whatever tree the script was run from. An output dir that resolves into a git
# repository (symlinks followed, gitignored paths such as a run dir included, a bare repo
# too) is REFUSED with exit 2 before any network call or write.
# GH_ATTACHMENTS_RESOLVE_ONLY=1 prints the resolved dir and stops (no network, no write).
# bin/night-janitor.sh expires files under the same root (NJ_ATTACH_DAYS).
#
# Deps: gh (authenticated), curl, file. Engine-generic; no project specifics.
#
# Auth: images/videos download with no auth header (signed jwt urls). Non-image
# FILES (.docx/.pdf) need a CLASSIC read-only PAT that a fine-grained PAT 404s on.
# Point GH_ATTACHMENTS_TOKEN at that classic token to enable file downloads without
# touching your normal gh auth; otherwise the ambient `gh auth token` is used.

set -uo pipefail
umask 077

die() { echo "gh-attachments: $*" >&2; exit 1; }
command -v gh   >/dev/null 2>&1 || die "gh not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v file >/dev/null 2>&1 || die "file not found"

# --- parse args -> owner / repo / num ---
owner="" repo="" num=""
if [ $# -eq 1 ]; then
  u="$1"
  if [[ "$u" =~ github\.com/([^/]+)/([^/]+)/(issues|pull)/([0-9]+) ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[4]}"
  else
    die "unrecognised URL: $u (expected https://github.com/OWNER/REPO/issues|pull/NUM)"
  fi
elif [ $# -eq 2 ]; then
  case "$1" in
    */*) owner="${1%%/*}"; repo="${1#*/}"; num="$2" ;;
    *)   die "expected OWNER/REPO NUM" ;;
  esac
else
  die "usage: gh-attachments.sh <issue-or-pr-url> | <owner>/<repo> <number>"
fi
[[ "$num" =~ ^[0-9]+$ ]] || die "number must be numeric: $num"

# --- output dir: resolved and checked BEFORE any network call or write ---
_home="${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
root="${GH_ATTACHMENTS_DIR:-${_home:?no HOME}/scratch/gh-attachments}"
case "$root" in /*) : ;; *) root="$PWD/$root" ;; esac
outdir="$root/${owner}-${repo}-${num}"
# Where the files would really land: the deepest existing part of the path (a dangling
# symlink counts and is followed), with symlinks resolved.
_real="$outdir"
for _i in 1 2 3 4 5 6 7 8; do
  _probe="$_real"
  while [ ! -e "$_probe" ] && [ ! -L "$_probe" ] && [ "$_probe" != / ]; do _probe="$(dirname "$_probe")"; done
  _real="$(readlink -f -- "$_probe")" || { echo "gh-attachments: REFUSED -- cannot resolve $_probe; nothing written" >&2; exit 2; }
  [ -e "$_real" ] && break
done
# Ask git about THAT path only. An inherited GIT_DIR/GIT_WORK_TREE would make git answer for
# another repository, so they are dropped. A bare repo or a .git dir counts as inside, and a
# git that cannot answer (for example "dubious ownership") is a refusal, not a pass.
_gitq() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
            -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM -u GIT_NAMESPACE git -C "$_real" "$@"; }
_ans="$(_gitq rev-parse --is-inside-work-tree --is-inside-git-dir 2>&1)"; _grc=$?
if [ "$_grc" -ne 0 ] && ! grep -qi 'not a git repository' <<<"$_ans"; then
  echo "gh-attachments: REFUSED -- cannot tell whether $_real is inside a git repository (git: ${_ans%%$'\n'*}). Nothing written." >&2
  exit 2
fi
if grep -qx true <<<"$_ans"; then
  echo "gh-attachments: REFUSED -- $outdir resolves into a git repository ($_real; work tree: $(_gitq rev-parse --show-toplevel 2>/dev/null || echo bare)). Attachments never go inside a repository; set GH_ATTACHMENTS_DIR outside every git tree. Nothing written." >&2
  exit 2
fi
if [ "${GH_ATTACHMENTS_RESOLVE_ONLY:-0}" = 1 ]; then echo "gh-attachments: output dir $outdir"; exit 0; fi

# Auth token for the fallback header. Prefer a DEDICATED download token
# (GH_ATTACHMENTS_TOKEN) when set -- a classic read-only PAT that can fetch
# non-image user-attachments/files, which a fine-grained PAT 404s on -- WITHOUT
# replacing the normal gh auth. Fall back to the ambient gh token otherwise.
token="${GH_ATTACHMENTS_TOKEN:-$(gh auth token 2>/dev/null || true)}"
[ -n "$token" ] || die "no token (set GH_ATTACHMENTS_TOKEN or run: gh auth login)"

mkdir -p -m 700 "$root" && mkdir -p -m 700 "$outdir" || die "cannot create $outdir"

# --- gather body_html from the issue/PR body + all comments ---
# The issues endpoint serves the conversation body + comments for BOTH issues and
# PRs. (PR review/diff comments are a separate endpoint and rarely carry attachments.)
# A failed call (wrong number, no access, gh not logged in) must not read as
# "no attachments found" with exit 0; gh prints its own error on stderr.
body="$(gh api "repos/$owner/$repo/issues/$num" \
     -H "Accept: application/vnd.github.full+json" --jq '.body_html')" \
  || die "gh api failed for $owner/$repo#$num"
comments="$(gh api --paginate "repos/$owner/$repo/issues/$num/comments" \
     -H "Accept: application/vnd.github.full+json" --jq '.[].body_html')" \
  || die "gh api failed reading the comments of $owner/$repo#$num"
html="$body"$'\n'"$comments"
[ -n "$body$comments" ] || echo "gh-attachments: note: empty body_html (ticket may have no text)" >&2

# --- extract attachment urls (dedup, keep first-seen order) ---
# Forms: signed jwt image/video urls (download with NO auth) + the plain
# user-attachments/{assets,files} urls (download WITH the gh token).
urls="$(printf '%s\n' "$html" \
  | grep -oE 'https://(private-user-images\.githubusercontent\.com/[^"'"'"' <>]+|github\.com/user-attachments/(assets|files)/[^"'"'"' <>]+)' \
  | awk '!seen[$0]++')"

if [ -z "$urls" ]; then
  echo "gh-attachments: no attachments found on $owner/$repo#$num"
  exit 0
fi

# Attempt 1: no auth header (works for signed jwt urls). Attempt 2 on failure: gh
# token header (works for github.com/user-attachments urls that 404 unauthenticated
# -- the exact case that was misdiagnosed as "needs a browser login").
_fetch() {  # url out -> prints http_code
  local url="$1" out="$2" code
  code="$(curl -sSL -m 60 -w '%{http_code}' -o "$out" "$url" 2>/dev/null || echo 000)"
  if [ "$code" != 200 ] || [ ! -s "$out" ]; then
    code="$(curl -sSL -m 60 -w '%{http_code}' -o "$out" \
              -H "Authorization: token $token" "$url" 2>/dev/null || echo 000)"
  fi
  echo "$code"
}

printf '\n%-3s | %-46s | %-38s | %-24s | %9s\n' "IDX" "SOURCE (jwt query stripped)" "SAVED FILE" "TYPE" "SIZE"
printf -- '----+------------------------------------------------+----------------------------------------+--------------------------+----------\n'

i=0 ok=0 fail=0
while IFS= read -r url; do
  [ -n "$url" ] || continue
  i=$((i+1))
  base="${url##*/}"; base="${base%%\?*}"          # filename, drop any ?jwt=...
  [ -n "$base" ] || base="attachment-$i"
  fname="$(printf '%02d-%s' "$i" "$base")"
  out="$outdir/$fname"
  code="$(_fetch "$url" "$out")"
  disp="${url%%\?*}"; disp="${disp#https://}"      # url without scheme + jwt query
  if [ "$code" = 200 ] && [ -s "$out" ]; then
    ok=$((ok+1))
    typ="$(file -b --mime-type "$out" 2>/dev/null || echo unknown)"
    sz="$(stat -c %s "$out" 2>/dev/null || wc -c < "$out")"
    szh="$(numfmt --to=iec --suffix=B "$sz" 2>/dev/null || echo "${sz}B")"
    printf '%-3s | %-46.46s | %-38.38s | %-24.24s | %9s\n' "$i" "$disp" "$fname" "$typ" "$szh"
  else
    fail=$((fail+1))
    rm -f "$out" 2>/dev/null
    printf '%-3s | %-46.46s | %-38.38s | %-24.24s | %9s\n' "$i" "$disp" "(FAILED http $code)" "-" "-"
  fi
done <<< "$urls"

echo
echo "gh-attachments: $ok downloaded, $fail failed -> $outdir"

# Self-diagnosis: a fine-grained PAT (github_pat_...) canNOT authenticate
# user-attachments/{assets,files} downloads -- GitHub returns 404. Images/videos
# still succeed via the no-auth signed (jwt) urls, but plain FILE attachments have
# no jwt rewrite, so they need a CLASSIC PAT (ghp_...) or an oauth login.
if [ "$fail" -gt 0 ]; then
  case "$token" in
    github_pat_*)
      {
        echo "gh-attachments: NOTE: the auth token is a fine-grained PAT (github_pat_...)."
        echo "  GitHub does not authenticate user-attachments downloads with a fine-grained"
        echo "  PAT, so plain file attachments 404. Images/videos still work (no-auth jwt),"
        echo "  but files need a CLASSIC read-only PAT (ghp_...). Provide one WITHOUT changing"
        echo "  your normal gh auth: export GH_ATTACHMENTS_TOKEN=<classic ghp_ token>, then re-run."
      } >&2
      ;;
  esac
fi

[ "$fail" -eq 0 ] || exit 1
exit 0
