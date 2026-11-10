#!/usr/bin/env python3
"""Send a message on the inter-session bus from daemon/cron context.

send.py walks /proc for a Claude Code session ancestor to find the listener
state file.  From a daemon or cron job there is no such ancestor, so send.py
prints "not connected" and exits 1 on every call — all nine daemon call sites
silently fail.

This script bypasses the ancestor walk.  It reads the shared token from
~/.claude/data/inter-session/token, connects to the bus server directly,
registers as a transient AGENT peer under --name, sends --text to --to,
and disconnects.  The bus is the one on --port, else INTER_SESSION_PORT, else
TEAM_PORT (bin/team-env.sh exports both); with none of them it refuses, since
the skill's default port is not a team bus.  Every network step is bounded.
Exit 0 on success, 1 on any failure, 2 on a usage error or no bus port.

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
    # `shared` (whose skill_command() names the installed command) is not imported yet here.
    print("dependencies missing: run the inter-session skill's install-deps command", file=sys.stderr)
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

# Bounds. A bus that accepted the TCP connection and then said nothing (overloaded, half-open, a
# squatter that passed the pidfile check) held the caller forever at the welcome recv, and the callers
# are daemon loops. Each step (handshake, welcome, send, close) now has its own limit; a step that
# times out sends nothing and exits 1 with one stderr line.
_STEP_S = 5.0
# The server sends no acknowledgement for a successful send. Until a `pong` (see _await_outcome)
# or an `error` arrives, this is how long a send waits. The server decides a direct message within
# twice its send timeout (once waiting behind other frames, once for the write) and reports a
# failed delivery before it answers the `ping`, so the wait outlasts that; a success is answered
# at once. Nothing within it is an error (delivery unknown), not a success: a bus that does not
# answer has confirmed nothing. An older skill has neither name: 5 s was its only bound.
_send_timeout = getattr(shared, "send_timeout_s", None)
_ACK_S = 2 * float(_send_timeout() if callable(_send_timeout)
                   else getattr(shared, "SEND_TIMEOUT_S", 5.0)) + 1.0


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

    # No port given: refuse. The skill's DEFAULT_PORT is never a team bus (team-env derives the team's
    # port from the clone and the run id), so a send there reached nobody while the caller saw rc 0.
    # TEAM_RUN_ID alone does not name the port either.
    port_str = (str(args.port) if args.port else "") or os.environ.get("INTER_SESSION_PORT") \
        or os.environ.get("TEAM_PORT")
    if not port_str:
        print("bus-send: no bus port: pass --port or set INTER_SESSION_PORT (bin/team-env.sh exports it; "
              f"TEAM_RUN_ID alone does not name the port). The skill's default port {shared.DEFAULT_PORT} "
              "is not a team bus; nothing was sent.", file=sys.stderr)
        return 2
    port = int(port_str)
    host = "127.0.0.1"

    if not shared.verify_server_identity(host, port):
        print(f"server identity check failed ({host}:{port})", file=sys.stderr)
        return 1

    try:
        return await _session(args, host, port, bus_token)
    except websockets.exceptions.ConnectionClosed as e:
        # A bus that accepts and then closes (crashing, restarting): one line, never a traceback.
        print(f"bus-send: bus at {host}:{port} closed the connection ({e.__class__.__name__}); "
              "outcome unknown", file=sys.stderr)
        return 1
    except websockets.exceptions.WebSocketException as e:
        print(f"bus-send: websocket error talking to {host}:{port} ({e.__class__.__name__}); "
              "outcome unknown", file=sys.stderr)
        return 1
    except asyncio.TimeoutError:
        # The bounded hello or payload send: the bus stopped taking frames. The connection is
        # closed with the frame unfinished, so nothing is delivered.
        print(f"bus-send: bus at {host}:{port} did not take a frame within {_STEP_S:g}s; nothing sent",
              file=sys.stderr)
        return 1


async def _session(args: argparse.Namespace, host: str, port: int, bus_token: str) -> int:
    sid = str(uuid.uuid4())
    nonce = str(uuid.uuid4())

    try:
        ws = await websockets.connect(
            f"ws://{host}:{port}/", max_size=shared.WS_FRAME_CAP,
            open_timeout=_STEP_S, close_timeout=2,
        )
    except asyncio.TimeoutError:   # before OSError: TimeoutError is an OSError since Python 3.11
        print(f"bus-send: no websocket handshake from {host}:{port} within {_STEP_S:g}s; nothing sent",
              file=sys.stderr)
        return 1
    except OSError as e:
        print(f"connect failed: {e}", file=sys.stderr)
        return 1

    try:
        await asyncio.wait_for(ws.send(json.dumps({
            "op": "hello",
            "session_id": sid,
            "name": args.name,
            "label": f"daemon:{args.name}",
            "cwd": os.getcwd(),
            "pid": os.getpid(),
            "role": shared.Role.AGENT.value,
            "nonce": nonce,
            "token": bus_token,
        })), timeout=_STEP_S)
        try:
            welcome_raw = await asyncio.wait_for(ws.recv(), timeout=_STEP_S)
        except asyncio.TimeoutError:
            print(f"bus-send: bus at {host}:{port} accepted but sent no welcome within {_STEP_S:g}s; "
                  "nothing sent", file=sys.stderr)
            return 1
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
        await asyncio.wait_for(ws.send(json.dumps(payload)), timeout=_STEP_S)
        resp = await _await_outcome(ws)
        if resp is not None:
            _last_refusal.clear()
            _last_refusal.update(code=resp.get("code", ""), message=resp.get("message", ""))
            err_msg = f"send error: {resp.get('code', '')}: {resp.get('message', '')}"
            if "matches" in resp:   # ambiguous prefix; a send error never carries candidates
                err_msg += f" (matches: {', '.join(resp['matches'])})"
            _last_refusal["line"] = err_msg
            if not _is_absent_refusal():
                print(err_msg, file=sys.stderr)   # an absent name is reported once, by main()
            return 1
    finally:
        try:
            await asyncio.wait_for(ws.close(), timeout=2)
        except Exception:
            pass

    print(f"sent -> {args.to} ({len(args.text)} chars)")
    return 0


async def _await_outcome(ws):
    """The send's `error` frame, or None once it went through.

    The server answers a successful send with nothing, so every success used to wait out the whole
    _ACK_S. It handles one connection's frames in order, so a `ping` sent right behind the send is
    answered only after the send was handled: `pong` means sent, an `error` before it is the send's
    refusal. Frames pushed to this peer meanwhile (peer_joined, msg) are skipped. No answer within
    _ACK_S is returned as a `no_answer` error: the message may or may not have been delivered."""
    silent = {"op": "error", "code": "no_answer",
              "message": f"no answer from the bus within {_ACK_S:g}s; delivery unknown"}
    try:
        await asyncio.wait_for(ws.send(json.dumps({"op": "ping"})), timeout=_STEP_S)
    except asyncio.TimeoutError:
        return silent
    loop = asyncio.get_running_loop()
    deadline = loop.time() + _ACK_S
    while True:
        left = deadline - loop.time()
        if left <= 0:
            return silent
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=left)
        except asyncio.TimeoutError:
            return silent
        try:
            frame = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(frame, dict):
            continue
        if frame.get("op") == "error":
            return frame
        if frame.get("op") == "pong":
            return None


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
    parser.add_argument("--port", type=int, default=0,
                        help="bus port; default INTER_SESSION_PORT, else TEAM_PORT; with none of "
                             "them the send is refused (exit 2)")
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
