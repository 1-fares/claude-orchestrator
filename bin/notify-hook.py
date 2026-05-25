#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""notify-hook.py: tiny HTTP service that turns ntfy action-button taps into
orchestrator actions. Singleton per host, no per-team state of its own.

  POST/GET /<action>/<run-id>?sig=<hex>&exp=<unix-ts>[&text=<urlencoded>]

actions:
  approve   send 'go' (or ?text=) into <run-id>'s orchestrator pane
  pause     broadcast 'pause:' to <run-id>
  resume    broadcast 'resume:'
  stop      broadcast 'stop: <text or "manual stop from phone">'
  priority  send 'priority: <text>' into the orchestrator pane (text required)

every request is rejected unless:
  - exp is in the future (default URL TTL: 30 min, set by signer)
  - sig is hex(hmac-sha256(secret, f"{method}\n{path}\n{exp}"))
  - secret comes from $NOTIFY_HOOK_SECRET or ~/.claude/notify-hook.secret

dispatches by exec'ing bin/approve.sh or bin/team-broadcast.sh in the orchestrator
clone, with TEAM_RUN_ID=<run-id> set. The hook holds no state and the actions
go through the same scripts a human would call by hand, so behaviour is auditable.

usage:
  bin/notify-hook.py                            # bind 127.0.0.1:8421
  bin/notify-hook.py --bind 0.0.0.0 --port 8421 # expose via tailnet
  bin/notify-hook.py --bind $(tailscale ip -4) --port 8421

set NOTIFY_HOOK_LOG to a path for an append-only audit log of every dispatch.
"""
import argparse, hashlib, hmac, json, os, secrets, shlex, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote

REPO = Path(__file__).resolve().parent.parent
SECRET_FILE = Path(os.environ.get("HOME", "/root")) / ".claude" / "notify-hook.secret"
AUDIT = os.environ.get("NOTIFY_HOOK_LOG", "")

ACTIONS = {"approve", "pause", "resume", "stop", "priority"}


def load_secret() -> bytes:
    s = os.environ.get("NOTIFY_HOOK_SECRET")
    if s:
        return s.encode()
    if not SECRET_FILE.exists():
        SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
        SECRET_FILE.write_text(secrets.token_hex(32))
        SECRET_FILE.chmod(0o600)
        print(f"notify-hook: generated new secret at {SECRET_FILE}", file=sys.stderr)
    return SECRET_FILE.read_text().strip().encode()


def expected_sig(secret: bytes, method: str, path: str, exp: str) -> str:
    msg = f"{method}\n{path}\n{exp}".encode()
    return hmac.new(secret, msg, hashlib.sha256).hexdigest()


def audit(line: str) -> None:
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {line}"
    print(line)
    if AUDIT:
        try:
            with open(AUDIT, "a") as f:
                f.write(line + "\n")
        except OSError as e:
            print(f"  audit-log write failed: {e}", file=sys.stderr)


def dispatch(action: str, run_id: str, text: str) -> tuple[int, str]:
    """Exec the right script. Never raises; returns (exit_code, stderr_excerpt)."""
    env = os.environ.copy()
    env["TEAM_RUN_ID"] = run_id
    if action == "approve":
        cmd = ["bash", str(REPO / "bin/approve.sh"), text or "go"]
    elif action == "pause":
        cmd = ["bash", str(REPO / "bin/team-broadcast.sh"), f"pause: {text or 'paused via phone'}"]
    elif action == "resume":
        cmd = ["bash", str(REPO / "bin/team-broadcast.sh"), f"resume: {text or 'resumed via phone'}"]
    elif action == "stop":
        cmd = ["bash", str(REPO / "bin/team-broadcast.sh"), f"stop: {text or 'stop via phone'}"]
    elif action == "priority":
        if not text:
            return 2, "priority action needs ?text=..."
        cmd = ["bash", str(REPO / "bin/approve.sh"), f"priority: {text}"]
    else:
        return 2, f"unknown action: {action}"
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    return p.returncode, (p.stderr or p.stdout or "").strip()[:300]


class Handler(BaseHTTPRequestHandler):
    server_version = "notify-hook/1.0"

    def _reply(self, code: int, body: str) -> None:
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _handle(self) -> None:
        u = urlparse(self.path)
        parts = [p for p in u.path.split("/") if p]
        if len(parts) != 2:
            return self._reply(404, "expected /<action>/<run-id>")
        action, run_id = parts[0], unquote(parts[1])
        if action not in ACTIONS:
            return self._reply(404, f"unknown action: {action}")
        q = parse_qs(u.query)
        sig = (q.get("sig") or [""])[0]
        exp = (q.get("exp") or ["0"])[0]
        text = (q.get("text") or [""])[0]
        try:
            if int(exp) < int(time.time()):
                audit(f"REJECT expired action={action} rid={run_id}")
                return self._reply(403, "url expired")
        except ValueError:
            return self._reply(400, "bad exp")
        want = expected_sig(SECRET, self.command, u.path, exp)
        if not hmac.compare_digest(want, sig):
            audit(f"REJECT bad-sig action={action} rid={run_id} from={self.client_address[0]}")
            return self._reply(403, "bad signature")
        rc, msg = dispatch(action, run_id, text)
        audit(f"DISPATCH action={action} rid={run_id} text={shlex.quote(text)[:60]} rc={rc} from={self.client_address[0]} msg={msg[:120]}")
        if rc == 0:
            return self._reply(200, f"ok: {action} -> {run_id}\n{msg}\n")
        return self._reply(500, f"dispatch failed (rc={rc}):\n{msg}\n")

    def do_GET(self): self._handle()
    def do_POST(self): self._handle()
    def log_message(self, fmt, *args): pass  # we audit ourselves


def main() -> None:
    global SECRET
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bind", default="127.0.0.1", help="bind address (default 127.0.0.1)")
    ap.add_argument("--port", type=int, default=8421, help="bind port (default 8421)")
    args = ap.parse_args()
    SECRET = load_secret()
    srv = HTTPServer((args.bind, args.port), Handler)
    audit(f"notify-hook: listening on http://{args.bind}:{args.port}  secret={SECRET_FILE}  actions={','.join(sorted(ACTIONS))}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        audit("notify-hook: stopped (SIGINT)")


if __name__ == "__main__":
    main()
