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
# Output dir (first that applies):
#   $GH_ATTACHMENTS_DIR/<owner>-<repo>-<num>/
#   $TEAM_DIR/attachments/<owner>-<repo>-<num>/
#   ./gh-attachments/<owner>-<repo>-<num>/
#
# Deps: gh (authenticated), curl, file. Engine-generic; no project specifics.

set -uo pipefail

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

token="$(gh auth token 2>/dev/null || true)"
[ -n "$token" ] || die "no gh token (run: gh auth login)"

# --- output dir ---
root="${GH_ATTACHMENTS_DIR:-}"
if [ -z "$root" ]; then
  if [ -n "${TEAM_DIR:-}" ]; then root="$TEAM_DIR/attachments"; else root="$PWD/gh-attachments"; fi
fi
outdir="$root/${owner}-${repo}-${num}"
mkdir -p "$outdir" || die "cannot create $outdir"

# --- gather body_html from the issue/PR body + all comments ---
# The issues endpoint serves the conversation body + comments for BOTH issues and
# PRs. (PR review/diff comments are a separate endpoint and rarely carry attachments.)
html="$(
  gh api "repos/$owner/$repo/issues/$num" \
     -H "Accept: application/vnd.github.full+json" --jq '.body_html' 2>/dev/null
  gh api --paginate "repos/$owner/$repo/issues/$num/comments" \
     -H "Accept: application/vnd.github.full+json" --jq '.[].body_html' 2>/dev/null
)"
[ -n "$html" ] || echo "gh-attachments: note: empty body_html (ticket may have no text)" >&2

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
        echo "gh-attachments: NOTE: your gh token is a fine-grained PAT (github_pat_...)."
        echo "  GitHub does not authenticate user-attachments downloads with a fine-grained"
        echo "  PAT, so plain file attachments 404. Images/videos still work (no-auth jwt),"
        echo "  but files need a CLASSIC PAT or oauth login. Fix: export GH_TOKEN=<classic ghp_ token>"
        echo "  (or run: gh auth login) and re-run."
      } >&2
      ;;
  esac
fi

[ "$fail" -eq 0 ] || exit 1
exit 0
