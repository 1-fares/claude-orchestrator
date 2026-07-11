#!/usr/bin/env bash
# probe-env.sh: detect a code project's toolchain and print its build/test/lint
# commands plus a ready-to-use `verify:` line, from marker files only (no builds
# run). Use at the start of work on an unfamiliar repo, or to fill a task brief's
# verify: field. Language-agnostic; prints `lang: unknown` and exits 1 if nothing
# recognized.
#
#   bin/tools/probe-env.sh [DIR]     # DIR defaults to the current directory
set -uo pipefail

dir="${1:-.}"
cd "$dir" 2>/dev/null || { echo "probe-env: not a directory: $dir" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }
emit() { printf '%s: %s\n' "$1" "$2"; }

lang="" build="" test="" lint=""

if [ -f package.json ]; then
  lang="node"; pm="npm"; run="npm run"
  [ -f pnpm-lock.yaml ] && { pm="pnpm"; run="pnpm"; }
  [ -f yarn.lock ] && { pm="yarn"; run="yarn"; }
  scripts=""
  have jq && scripts="$(jq -r '.scripts // {} | keys[]' package.json 2>/dev/null)"
  has() { printf '%s\n' "$scripts" | grep -qx "$1"; }
  has build && build="$run build"
  if has test; then test="$pm test"; fi
  has lint && lint="$run lint"
  has typecheck && { [ -n "$lint" ] && lint="$lint && $run typecheck" || lint="$run typecheck"; }
  [ -z "$build" ] && build="$pm install"
elif [ -f Cargo.toml ]; then
  lang="rust"; build="cargo build"; test="cargo test"; lint="cargo clippy -- -D warnings"
elif [ -f go.mod ]; then
  lang="go"; build="go build ./..."; test="go test ./..."; lint="go vet ./..."
elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f setup.cfg ]; then
  lang="python"
  runner="python -m pytest -q"
  { have uv && [ -f uv.lock ]; } && runner="uv run pytest -q"
  test="$runner"; build="python -m build"
  if grep -qi 'ruff' pyproject.toml setup.cfg 2>/dev/null; then lint="ruff check ."
  elif grep -qi 'flake8' pyproject.toml setup.cfg tox.ini 2>/dev/null; then lint="flake8"; fi
elif ls ./*.csproj >/dev/null 2>&1 || ls ./*.sln >/dev/null 2>&1; then
  lang="dotnet"; build="dotnet build"; test="dotnet test"; lint="dotnet format --verify-no-changes"
elif [ -f pom.xml ]; then
  lang="maven"; build="mvn -q -DskipTests package"; test="mvn -q test"
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  lang="gradle"; g="gradle"; [ -x ./gradlew ] && g="./gradlew"
  build="$g build -x test"; test="$g test"
elif [ -f Gemfile ]; then
  lang="ruby"; test="bundle exec rake test"; [ -d spec ] && test="bundle exec rspec"
  lint="bundle exec rubocop"
elif [ -f composer.json ]; then
  lang="php"; test="composer test"; [ -f phpunit.xml ] && test="./vendor/bin/phpunit"
fi

# A Makefile can supply or override targets for any language.
mk=""; [ -f Makefile ] && mk=Makefile; [ -z "$mk" ] && [ -f makefile ] && mk=makefile
if [ -n "$mk" ]; then
  grep -qE '^build:' "$mk" && [ -z "$build" ] && build="make build"
  grep -qE '^test:'  "$mk" && test="make test"
  grep -qE '^lint:'  "$mk" && [ -z "$lint" ] && lint="make lint"
  grep -qE '^check:' "$mk" && [ -z "$test" ] && test="make check"
  [ -z "$lang" ] && lang="make"
fi

[ -z "$lang" ] && { echo "lang: unknown (no recognized project markers in $dir)"; exit 1; }

emit lang "$lang"
[ -n "$build" ] && emit build "$build"
[ -n "$test" ]  && emit test  "$test"
[ -n "$lint" ]  && emit lint  "$lint"

v="$test"
[ -n "$lint" ] && { [ -n "$v" ] && v="$v && $lint" || v="$lint"; }
[ -n "$v" ] && emit suggested-verify "$v"
exit 0
