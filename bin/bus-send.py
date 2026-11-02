#!/usr/bin/env python3
"""Send a message on the inter-session bus from daemon/cron context.

send.py walks /proc for a Claude Code session ancestor to find the listener
state file.  From a daemon or cron job there is no such ancestor, so send.py
prints "not connected" and exits 1 on every call — all nine daemon call sites
silently fail.

This script bypasses the ancestor walk.  It reads the shared token from
~/.claude/data/inter-session/token, connects to the bus server directly,
registers as a transient AGENT peer under --name, sends --text to --to,
and disconnects.  Exit 0 on success, 1 on any failure.

Runs under the inter-session venv (same bootstrap as send.py).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

_VENV = Path.home() / ".claude" / "data" / "inter-session" / "venv"
_VENV_PY = _VENV / "bin" / "python"
if (not os.environ.get("INTER_SESSION_NO_REEXEC")
        and _VENV_PY.is_file()
        and Path(sys.prefix).resolve() != _VENV.resolve()):
    os.execv(str(_VENV_PY), [str(_VENV_PY), *sys.argv])

import argparse
import asyncio
import json
import uuid

try:
    import websockets
except ImportError:
    print("dependencies missing — run /inter-session install-deps", file=sys.stderr)
    sys.exit(1)

_SKILL_DIR = Path(__file__).resolve().parent.parent / ".claude" / "skills" / "is" / "bin"
if not _SKILL_DIR.exists():
    _SKILL_DIR = Path.home() / ".claude" / "skills" / "is" / "bin"
sys.path.insert(0, str(_SKILL_DIR))

import shared  # noqa: E402

# The server keeps nothing for a name that is not connected: the send is refused with unknown_peer
# and the message exists nowhere. A role is off the bus for a few seconds whenever its listener
# restarts (crash, session respawn, team relaunch), and every send in that window was lost. A refusal
# for a name that is ABSENT ("no agent matches") is retried every _RETRY_STEP s for up to
# BUS_SEND_RETRY_S (default 30); after that the exit and the last stderr line are exactly as before
# (rc 1, "send error: unknown_peer: ..."). Self-sends and every other error are not retried.
# A caller with its own outer timeout or a tight loop sets BUS_SEND_RETRY_S=0.
# Parsing is strict: UNSET = 30; anything that is not a finite number > 0 (empty, "off", "nan",
# negative, 0) = off -- a value someone set means they wanted to change it, and "off" must never
# mean 30 s; a finite value is clamped to _RETRY_MAX_S, so "inf" cannot hold a caller forever.
_RETRY_MAX_S = 60.0


def _parse_retry(raw):
    import math
    if raw is None:
        return 30.0
    try:
        v = float(raw)
    except ValueError:
        return 0.0
    if math.isnan(v) or v <= 0:
        return 0.0
    return min(v, _RETRY_MAX_S)


_RETRY_S = _parse_retry(os.environ.get("BUS_SEND_RETRY_S"))
_RETRY_STEP = 2.0
_last_refusal: dict = {}


def _is_absent_refusal() -> bool:
    return (_last_refusal.get("code") == shared.ErrorCode.UNKNOWN_PEER
            and str(_last_refusal.get("message", "")).startswith("no agent matches"))


async def _run(args: argparse.Namespace) -> int:
    token_file = shared.token_path()
    if not token_file.exists():
        print(f"no token at {token_file} — bus server never started", file=sys.stderr)
        return 1
    try:
        bus_token = token_file.read_text().strip()
    except OSError as e:
        print(f"cannot read token: {e}", file=sys.stderr)
        return 1
    if not bus_token:
        print("token file is empty", file=sys.stderr)
        return 1

    port_str = os.environ.get("INTER_SESSION_PORT") or os.environ.get("TEAM_PORT")
    port = int(port_str) if port_str else shared.DEFAULT_PORT
    host = "127.0.0.1"

    if not shared.verify_server_identity(host, port):
        print(f"server identity check failed ({host}:{port})", file=sys.stderr)
        return 1

    sid = str(uuid.uuid4())
    nonce = str(uuid.uuid4())

    try:
        ws = await websockets.connect(
            f"ws://{host}:{port}/", max_size=shared.WS_FRAME_CAP,
        )
    except OSError as e:
        print(f"connect failed: {e}", file=sys.stderr)
        return 1

    try:
        await ws.send(json.dumps({
            "op": "hello",
            "session_id": sid,
            "name": args.name,
            "label": f"daemon:{args.name}",
            "cwd": os.getcwd(),
            "pid": os.getpid(),
            "role": shared.Role.AGENT.value,
            "nonce": nonce,
            "token": bus_token,
        }))
        welcome_raw = await ws.recv()
        welcome = json.loads(welcome_raw)
        if welcome.get("op") == "error":
            code = welcome.get("code", "")
            msg = welcome.get("message", "")
            if code == shared.ErrorCode.NAME_TAKEN:
                print(f"name '{args.name}' already taken on the bus", file=sys.stderr)
            else:
                print(f"hello error: {code} {msg}", file=sys.stderr)
            return 1

        payload = {"op": "send", "to": args.to, "text": args.text}
        await ws.send(json.dumps(payload))

        try:
            resp_raw = await asyncio.wait_for(ws.recv(), timeout=2.0)
            resp = json.loads(resp_raw)
            if resp.get("op") == "error":
                _last_refusal.clear()
                _last_refusal.update(code=resp.get("code", ""), message=resp.get("message", ""))
                err_msg = f"send error: {resp.get('code', '')}: {resp.get('message', '')}"
                if "candidates" in resp:
                    err_msg += f" (try: {', '.join(resp['candidates'])})"
                _last_refusal["line"] = err_msg
                if not _is_absent_refusal():
                    print(err_msg, file=sys.stderr)   # an absent name is reported once, by main()
                return 1
        except asyncio.TimeoutError:
            pass
    finally:
        await ws.close()

    print(f"sent -> {args.to} ({len(args.text)} chars)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send one message on the inter-session bus from daemon/cron context."
    )
    parser.add_argument("--name", default=os.environ.get("BUS_SEND_NAME", ""),
                        help="register under this name (e.g. deploy-announce); "
                             "default from BUS_SEND_NAME env")
    parser.add_argument("--to", required=True,
                        help="target peer name")
    parser.add_argument("--text", required=True,
                        help="message text")
    args = parser.parse_args()
    if not args.name:
        parser.error("--name required (or set BUS_SEND_NAME env)")
    import time
    t0 = time.monotonic()
    tries = 0
    while True:
        tries += 1
        _last_refusal.clear()
        rc = asyncio.run(_run(args))
        absent = rc == 1 and _is_absent_refusal()
        if not absent or time.monotonic() - t0 + _RETRY_STEP > _RETRY_S:
            if absent:
                # ONE line, starting exactly as before: callers match it for unknown_peer.
                line = _last_refusal.get("line", "send error: unknown_peer")
                if tries > 1:
                    line += f" [absent through {tries} tries over {time.monotonic() - t0:.0f}s; NOT sent]"
                sys.stderr.write(line + "\n")
            elif rc == 0 and tries > 1:
                sys.stderr.write(f"bus-send: {args.to} was off the bus; sent on try {tries}\n")
            return rc
        time.sleep(_RETRY_STEP)


if __name__ == "__main__":
    sys.exit(main())
