#!/usr/bin/env bash
# trust-workdir.sh: pre-accept Claude Code's workspace-trust dialog for a
# directory, so interactive role sessions launched there (launch-team --workdir)
# do not stop at the "Do you trust the files in this folder?" prompt.
#
# Why this exists: the trust dialog is auto-skipped only in non-interactive mode
# (claude -p / non-TTY), but roles must run interactively. Trust is recorded
# per-directory in ~/.claude.json (the hasTrustDialogAccepted flag). This script
# sets that flag, editing ~/.claude.json atomically (tmp + rename) and keeping a
# ~/.claude.json.bak, preserving every other key. The launchers call it for an
# untrusted target; you can also run it by hand.
#
# Usage: bin/trust-workdir.sh <dir>

set -euo pipefail

dir="${1:?usage: trust-workdir.sh <dir>}"
abs="$(cd "$dir" 2>/dev/null && pwd)" || { echo "not a directory: $dir" >&2; exit 1; }
cfg="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
[ -f "$cfg" ] || { echo "no $cfg; start claude once first" >&2; exit 1; }

python3 - "$cfg" "$abs" <<'PY'
import json, os, sys, tempfile, shutil
cfg, abs = sys.argv[1], sys.argv[2]
with open(cfg) as f:
    d = json.load(f)
proj = d.setdefault("projects", {})
e = proj.setdefault(abs, {})
before = e.get("hasTrustDialogAccepted")
if before is True:
    print(f"already trusted: {abs}")
    sys.exit(0)
e["hasTrustDialogAccepted"] = True
e.setdefault("hasCompletedProjectOnboarding", True)
shutil.copy2(cfg, cfg + ".bak")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cfg) or ".")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, cfg)
finally:
    if os.path.exists(tmp):
        os.remove(tmp)
print(f"trusted: {abs} (was {before}); backup at {cfg}.bak")
PY
