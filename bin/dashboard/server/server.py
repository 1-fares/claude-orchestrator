#!/usr/bin/env python3
"""B11 dashboard, read-only HTTP server for a live orchestrator run.

Reads $TEAM_DIR/{active,state.md,health/*.json} and the inter-session bus log,
serves a snapshot at /state.json plus static assets from bin/dashboard/. See
$TEAM_DIR/artifacts/u4-architecture.md for the full contract.

Stdlib only. Single-threaded HTTPServer; snapshot built per request. Bind is
hard-restricted to loopback (127.0.0.1, ::1, localhost).

Endpoints:
  GET /              static index.html
  GET /static/<file> static asset (allow-listed CSS/JS)
  GET /static/img/<basename>
                     image asset under bin/dashboard/static/img/. Basename
                     must match IMG_BASENAME_RE (lowercase png/webp/svg/jpeg
                     files) and the resolved realpath must stay under that dir.
  GET /state.json    full snapshot, schema_version=2
  GET /role-feed/<name>?limit=N
                     per-role bus traffic feed for the click-to-stream panel
                     (u4-server-feed). Returns the last N messages (default
                     100, max 500) involving <name> as sender or receiver,
                     chronologically (newest last). Response shape:
                       {"role": "<name>", "schema_version": 2,
                        "messages": [
                          {"id", "ts", "direction" (sent|received),
                           "peer" (role name or "all" for broadcasts),
                           "prefix" (status/done/question/answer/priority/
                                     pause/resume/other),
                           "body_preview" (first 160 chars)},
                          ...]}
                     400 on invalid role name (^[a-z0-9][a-z0-9-]{0,39}$),
                     404 on a name never seen on the bus and not in $TEAM_DIR/active.
  GET /themes        list of installed themes for the u13 switcher
                     (u14-server-themes). Walks bin/dashboard/static/themes/
                     once at startup, parses each subdir's theme.json against
                     the u11 master-spec contract, and returns the validated
                     list. Themes whose theme.json is malformed or fails
                     validation are excluded and a single stderr warning per
                     theme is emitted at load time. Response shape:
                       {"schema_version": 2,
                        "themes": [<theme.json object>, ...]}
                     The cache is rebuilt on SIGHUP (or any restart); it does
                     NOT auto-watch the filesystem, so operators must HUP or
                     restart to pick up newly installed themes.
  GET /static/themes/<theme>/<file>
                     theme asset under bin/dashboard/static/themes/<theme>/.
                     <theme> must match THEME_NAME_RE and resolve to an
                     existing subdir; <file> must match THEME_FILE_RE and the
                     resolved realpath must stay under that subdir.
  GET /chat?since=<ts-or-msgid>
                     conversation.jsonl entries strictly newer than the
                     cursor. Cursor is empty (all), an RFC 3339 UTC ts, or an
                     8 lowercase hex msg_id. At most 500 entries per call.
                     Response: {"thread_id", "schema_version", "since",
                     "entries": [...]}. 400 on malformed cursor.
  POST /chat         operator-side write surface. JSON body
                     `{"author_name", "body", "addressed_to"?}`. Server appends
                     a JSONL entry to $TEAM_DIR/comm/inbound.jsonl with a
                     server-stamped `ts`, `author_type="operator"`, and
                     `msg_id=null`. 202 on accept. 400 on missing author_name
                     or body, malformed JSON, body > 256 KB, or addressed_to
                     not matching `operator|orchestrator|role:<name>`.
  GET /chat/open-question
                     contents of $TEAM_DIR/comm/open-question.json verbatim,
                     or `{}` if absent.
  GET /chat/queue    contents of $TEAM_DIR/comm/question-queue.jsonl as a JSON
                     array (one element per line), or `[]` if absent.
  GET /healthz       liveness probe

SCHEMA_VERSION history:
  1 — initial /state.json + /role-feed shape.
  2 — added /themes and /static/themes/<theme>/<file>. /state.json shape is
       unchanged at the field level; the version bump signals to clients that
       the theme endpoints exist (clients that ignore them stay backward
       compatible because /state.json payload is unchanged).
  3 — added /chat surface for the communicator role (u30): GET /chat,
       POST /chat, GET /chat/open-question, GET /chat/queue. Reads and writes
       $TEAM_DIR/comm/* with realpath containment. /state.json payload shape
       is unchanged at the field level.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import signal
import socket
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Optional
from urllib.parse import parse_qs, urlsplit

SCHEMA_VERSION = 3
RECENT_WINDOW_SEC = 30.0           # server-side message retention window
ACTIVE_RECENT_SEC = 3.0            # "active" rule 6: msg within this window
RING_MAX = 500                     # cache ring size
SERIALIZE_MAX = 200                # max messages in snapshot
TIMELINE_MAX = 8
QUESTION_TTL_SEC = 30 * 60         # prune unanswered questions after 30 min
TAIL_BYTES = 256 * 1024            # initial bus-log tail read
ROLE_FEED_TAIL_BYTES = 512 * 1024  # tail size for /role-feed/<name> reads
ROLE_FEED_DEFAULT = 100
ROLE_FEED_MAX = 500
ROLE_FEED_PREVIEW_CHARS = 160
ROLE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
PREFIXES = ("status", "done", "question", "answer", "priority", "pause", "resume")
LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}

# Allow-list of static asset filenames (relative to bin/dashboard/static/).
# u6 (frontend) owns the actual files; the server just refuses anything else.
STATIC_ALLOWLIST = (
    "tokens.css",
    "app.css",
    "app.js",
    "graph.js",
    "sidebar.js",
    "glyphs.js",
)

MIME_BY_EXT = {
    ".css": "text/css; charset=utf-8",
    ".js":  "application/javascript; charset=utf-8",
    ".html": "text/html; charset=utf-8",
    ".json": "application/json",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".webp": "image/webp",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
}

# /static/img/<basename> is served when the basename matches this pattern AND
# the file's realpath stays under bin/dashboard/static/img/. Extensions are
# part of the pattern, not arbitrary names.
IMG_BASENAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}\.(png|webp|svg|jpe?g)$")

# Theme directory + file gates for /static/themes/<theme>/<file>. The dir name
# follows the same kebab-case rule as the bus role-name pattern; the file
# basename is the IMG pattern plus the text formats themes need (tokens.css,
# theme.json, the per-asset prompt records).
THEME_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
THEME_FILE_RE = re.compile(
    r"^[a-z0-9][a-z0-9._-]{0,63}\.(png|webp|svg|jpe?g|css|json|txt)$"
)

# theme.json contract per $TEAM_DIR/design/themes/_master-spec.md §3.
THEME_REQUIRED_FIELDS = (
    "name", "display_name", "summary", "mode",
    "default_edge_style", "default_token_style",
)
THEME_MODES = {"dark", "light"}
THEME_EDGE_STYLES = {"solid", "ribbon", "streak", "spark"}
THEME_TOKEN_STYLES = {"spark", "disc", "ribbon", "streak"}
THEME_SUMMARY_MAX = 80

# /chat surface (u30). Backs the communicator role's push surface; reads and
# writes live under $TEAM_DIR/comm/. The /is bus enforces a 256 KB per-message
# cap and we mirror it on the POST body so an oversized operator turn cannot
# slip past the dashboard surface and then bounce off the bus elsewhere.
CHAT_BODY_MAX = 256 * 1024
CHAT_MAX_ENTRIES = 500
CHAT_MSGID_RE = re.compile(r"^[0-9a-f]{8}$")
CHAT_ADDRESSED_TO_RE = re.compile(
    r"^(operator|orchestrator|role:[a-z0-9][a-z0-9-]{0,39})$"
)


# ---------------------------------------------------------------------------
# Message cache (mutable, single-threaded — no lock needed).
# ---------------------------------------------------------------------------

@dataclass
class MessageCache:
    path: Optional[str] = None
    inode: Optional[int] = None
    pos: int = 0
    ring: list = field(default_factory=list)         # list[dict] in arrival order
    open_questions: dict = field(default_factory=dict)  # msg_id -> {from,to,ts}


@dataclass
class ServerState:
    team_dir_arg: Optional[str]
    static_dir: Path
    index_html: Path
    started_ts: float
    msg_cache: MessageCache
    # Theme registry: list of validated theme.json dicts, in directory-sorted
    # order. Rebuilt at startup and on SIGHUP. None means "not yet loaded";
    # an empty list means "no themes installed".
    themes: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# Team dir resolution.
# ---------------------------------------------------------------------------

def resolve_team_dir(cli_arg: Optional[str]) -> Optional[str]:
    """CLI arg > $TEAM_DIR > ./.team > newest ./.team-*. Returns abs path or None."""
    if cli_arg:
        return os.path.abspath(cli_arg)
    env = os.environ.get("TEAM_DIR")
    if env:
        return os.path.abspath(env)
    cwd_team = os.path.abspath("./.team")
    if os.path.isdir(cwd_team):
        return cwd_team
    candidates = sorted(
        (p for p in glob.glob("./.team-*") if os.path.isdir(p)),
        key=lambda p: os.path.getmtime(p),
        reverse=True,
    )
    if candidates:
        return os.path.abspath(candidates[0])
    return None


# ---------------------------------------------------------------------------
# Parsers.
# ---------------------------------------------------------------------------

def _safe_mtime(path: str) -> Optional[float]:
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def read_active(team_dir: Optional[str], warnings: list) -> list:
    if not team_dir:
        return []
    path = os.path.join(team_dir, "active")
    if not os.path.isfile(path):
        return []
    out = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 3:
                    warnings.append(f"$TEAM_DIR/active malformed at line {lineno}")
                    continue
                pid_s, win, name = parts[0], parts[1], parts[2]
                try:
                    pid = int(pid_s)
                except ValueError:
                    warnings.append(f"$TEAM_DIR/active malformed at line {lineno}")
                    continue
                out.append({"name": name, "pid": pid, "tmux_window": win})
    except OSError as e:
        warnings.append(f"$TEAM_DIR/active not readable: {e}")
    return out


_RE_UNIT_HEADER = re.compile(r"^##\s+unit:\s*(\S+)\s*$", re.MULTILINE)
_RE_SECTION = re.compile(r"^##\s+", re.MULTILINE)
_RE_KV = re.compile(r"^([a-zA-Z][a-zA-Z0-9_-]*):\s*(.+?)\s*$", re.MULTILINE)
_RE_ROSTER_LINE = re.compile(
    r"^\s*-\s*(\d{4}-\d{2}-\d{2})\s+([+\-])(\S+)(?:\s+\((.*)\))?\s*$"
)
_ALLOWED_STATUSES = {
    "todo", "assigned", "acked", "in-progress", "blocked", "review",
    "integrating", "done", "deferred",
}


def parse_state_md(team_dir: Optional[str], warnings: list) -> dict:
    counts = {s: 0 for s in _ALLOWED_STATUSES}
    out = {"counts": counts, "list": [], "timeline": []}
    if not team_dir:
        return out
    path = os.path.join(team_dir, "state.md")
    if not os.path.isfile(path):
        return out
    try:
        text = open(path, "r", encoding="utf-8").read()
    except OSError as e:
        warnings.append(f"state.md not readable: {e}")
        return out

    # Units: slice from each "## unit: X" header to the next "## " or EOF.
    headers = list(_RE_UNIT_HEADER.finditer(text))
    section_boundaries = [m.start() for m in _RE_SECTION.finditer(text)]
    for m in headers:
        uid = m.group(1)
        start = m.end()
        ends = [s for s in section_boundaries if s > start]
        end = ends[0] if ends else len(text)
        body = text[start:end]
        kvs = {k.lower(): v for k, v in _RE_KV.findall(body)}
        raw_status = kvs.get("status", "todo")
        if raw_status.startswith("blocked-on"):
            status = "blocked"
        else:
            status = raw_status
        if status not in _ALLOWED_STATUSES:
            warnings.append(f"state.md: unknown status '{raw_status}' for {uid}")
            status = "todo"
        counts[status] += 1
        depends = [
            d.strip() for d in kvs.get("depends-on", "-").split(",")
            if d.strip() and d.strip() != "-"
        ]
        out["list"].append({
            "id": uid,
            "owner": kvs.get("owner"),
            "status": status,
            "depends_on": depends,
        })

    # Roster section: timeline.
    roster_m = re.search(r"^##\s+roster\s*$", text, re.MULTILINE)
    if roster_m:
        next_hdr = _RE_SECTION.search(text, roster_m.end())
        end = next_hdr.start() if next_hdr else len(text)
        block = text[roster_m.end():end]
        events = []
        for line in block.splitlines():
            mm = _RE_ROSTER_LINE.match(line)
            if not mm:
                continue
            datestr, sign, role, note = mm.group(1), mm.group(2), mm.group(3), mm.group(4)
            try:
                ts = datetime.strptime(datestr, "%Y-%m-%d").timestamp()
            except ValueError:
                continue
            events.append({
                "ts": ts,
                "date": datestr,
                "kind": "add" if sign == "+" else "retire",
                "role": role,
                "source": "state.md:roster" + (f" ({note})" if note else ""),
            })
        # Most-recent first.
        events.sort(key=lambda e: e["ts"], reverse=True)
        out["timeline"] = events[:TIMELINE_MAX]

    return out


def read_health_dir(team_dir: Optional[str], warnings: list) -> dict:
    out: dict = {}
    if not team_dir:
        return out
    health_dir = os.path.join(team_dir, "health")
    if not os.path.isdir(health_dir):
        return out
    for path in sorted(glob.glob(os.path.join(health_dir, "*.json"))):
        role = os.path.basename(path)[:-5]
        try:
            data = json.loads(open(path, "r", encoding="utf-8").read())
            if isinstance(data, dict) and isinstance(data.get("state"), str):
                data["state"] = data["state"].lower()
            out[role] = data
        except (OSError, json.JSONDecodeError) as e:
            warnings.append(f"health/{role}.json: invalid json ({e})")
            out[role] = None
    return out


# ---------------------------------------------------------------------------
# Messages.
# ---------------------------------------------------------------------------

def _resolve_log_path() -> Optional[str]:
    override = os.environ.get("INTER_SESSION_LOG")
    if override:
        return override
    default = os.path.expanduser("~/.claude/data/inter-session/messages.log")
    return default if os.path.isfile(default) else None


_PREFIX_RE = re.compile(r"^(" + "|".join(PREFIXES) + r"):", re.IGNORECASE)


def _classify(text: str) -> str:
    if not isinstance(text, str):
        return "other"
    m = _PREFIX_RE.match(text[:32])
    return m.group(1).lower() if m else "other"


def _parse_iso(ts: str) -> Optional[float]:
    if not isinstance(ts, str):
        return None
    try:
        # 3.11+ accepts the trailing Z; we still see +00:00 from the bus client.
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def _record_to_msg(rec: dict) -> Optional[dict]:
    """Project a raw JSONL record into the schema's message shape, or None."""
    ts = _parse_iso(rec.get("ts"))
    if ts is None:
        return None
    kind = rec.get("kind") or "direct"
    fanout = None
    if kind == "broadcast":
        # Bus log records broadcast expansion per recipient (one row each); we
        # also accept an inline fanout array if present. v1: keep `to` set on
        # each fanned-out row; the recipient list is reconstructed by the
        # client from the message stream itself if needed.
        fanout = rec.get("broadcast_fanout") or rec.get("to_list") or None
    return {
        "id": rec.get("msg_id") or "",
        "ts": ts,
        "from": rec.get("from_name"),
        "to": rec.get("to") if kind == "direct" else (rec.get("to") or None),
        "kind": kind,
        "prefix": _classify(rec.get("text", "")),
        "broadcast_fanout": fanout,
    }


def _tail_jsonl(path: str, cache: MessageCache, warnings: list) -> None:
    """Refresh cache.ring from the log on disk, in-place. Pure I/O helper."""
    try:
        st = os.stat(path)
    except OSError as e:
        warnings.append(f"messages.log not readable: {e}")
        return
    rotated = (cache.path != path) or (cache.inode != st.st_ino) or (st.st_size < cache.pos)
    if rotated:
        cache.path = path
        cache.inode = st.st_ino
        # First request after start (or rotation): seek back ~256 KB.
        start_pos = max(0, st.st_size - TAIL_BYTES)
        try:
            with open(path, "rb") as fh:
                fh.seek(start_pos)
                if start_pos > 0:
                    fh.readline()  # discard partial line
                payload = fh.read()
            cache.pos = st.st_size
        except OSError as e:
            warnings.append(f"messages.log read failed: {e}")
            return
        cache.ring = []
        _append_records(cache, payload, warnings)
        return

    if st.st_size == cache.pos:
        return  # no new bytes

    try:
        with open(path, "rb") as fh:
            fh.seek(cache.pos)
            payload = fh.read()
        cache.pos = st.st_size
    except OSError as e:
        warnings.append(f"messages.log read failed: {e}")
        return
    _append_records(cache, payload, warnings)


def _append_records(cache: MessageCache, payload: bytes, warnings: list) -> None:
    for raw in payload.splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            warnings.append("messages.log: skipped malformed jsonl line")
            continue
        msg = _record_to_msg(rec)
        if msg is None:
            continue
        if not msg["from"] or (msg["kind"] == "direct" and not msg["to"]):
            warnings.append(f"messages.log: record {msg['id']} missing from/to")
            continue
        cache.ring.append(msg)
        # Track open questions / answers.
        prefix = msg["prefix"]
        if prefix == "question":
            cache.open_questions[msg["id"]] = {
                "from": msg["from"], "to": msg["to"], "ts": msg["ts"],
            }
        elif prefix == "answer":
            # Close the oldest open question from `to` directed at `from`.
            candidates = [
                (mid, q) for mid, q in cache.open_questions.items()
                if q["from"] == msg["to"] and q["to"] == msg["from"]
            ]
            if candidates:
                candidates.sort(key=lambda kv: kv[1]["ts"])
                cache.open_questions.pop(candidates[0][0], None)
    if len(cache.ring) > RING_MAX:
        cache.ring = cache.ring[-RING_MAX:]


def read_messages(now: float, cache: MessageCache, warnings: list) -> tuple:
    """Refresh the cache from disk and project to (msgs, opens, counts_by_role)."""
    path = _resolve_log_path()
    if path:
        _tail_jsonl(path, cache, warnings)
    else:
        warnings.append("messages.log: not found at default location and $INTER_SESSION_LOG unset")

    # Prune stale open questions.
    stale_cutoff = now - QUESTION_TTL_SEC
    for mid in list(cache.open_questions.keys()):
        if cache.open_questions[mid]["ts"] < stale_cutoff:
            cache.open_questions.pop(mid, None)

    window_cutoff = now - RECENT_WINDOW_SEC
    msgs = [m for m in cache.ring if m["ts"] >= window_cutoff]

    counts_by_role: dict = {}

    def _bump(role: str, key: str) -> None:
        if not role:
            return
        c = counts_by_role.setdefault(role, {
            "sent_1m": 0, "recv_1m": 0, "sent_total": 0, "recv_total": 0,
        })
        c[key] += 1

    minute_cutoff = now - 60.0
    for m in cache.ring:
        is_recent = m["ts"] >= minute_cutoff
        _bump(m["from"], "sent_total")
        if is_recent:
            _bump(m["from"], "sent_1m")
        if m["kind"] == "direct" and m["to"]:
            _bump(m["to"], "recv_total")
            if is_recent:
                _bump(m["to"], "recv_1m")
        elif m["kind"] == "broadcast" and isinstance(m["broadcast_fanout"], list):
            for tgt in m["broadcast_fanout"]:
                _bump(tgt, "recv_total")
                if is_recent:
                    _bump(tgt, "recv_1m")

    # Return the full open-question map; build_role groups by sender + age.
    return msgs, dict(cache.open_questions), counts_by_role


# ---------------------------------------------------------------------------
# Per-role feed (u4): backs GET /role-feed/<name>.
# Fresh tail per request — the cache in MessageCache projects records and
# drops session_ids, but the feed needs them to resolve recipients by name.
# Tail size is bounded; at 1 Hz dashboard polls this is cheap.
# ---------------------------------------------------------------------------

def _read_log_tail(log_path: str, tail_bytes: int, warnings: list) -> Optional[str]:
    try:
        st = os.stat(log_path)
        start_pos = max(0, st.st_size - tail_bytes)
        with open(log_path, "rb") as fh:
            fh.seek(start_pos)
            if start_pos > 0:
                fh.readline()  # discard partial line
            return fh.read().decode("utf-8", errors="replace")
    except OSError as e:
        warnings.append(f"messages.log read failed: {e}")
        return None


def read_role_feed(role_name: str, limit: int, log_path: Optional[str],
                   warnings: list) -> tuple[list, bool]:
    """Project the bus log into a per-role feed.

    Returns (messages, seen_in_log). `seen_in_log` is True when `role_name`
    has appeared as a sender anywhere in the tailed window — used by the
    handler to decide between 200 (known) and 404 (unknown), in concert
    with $TEAM_DIR/active.
    """
    if not log_path or not os.path.isfile(log_path):
        return [], False

    payload = _read_log_tail(log_path, ROLE_FEED_TAIL_BYTES, warnings)
    if payload is None:
        return [], False

    records: list = []
    sid_to_name: dict = {}
    for line in payload.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            warnings.append("messages.log: skipped malformed jsonl line")
            continue
        records.append(rec)
        sid = rec.get("from")
        nm = rec.get("from_name")
        # Most-recent name wins on session_id reuse (extremely rare; uuids).
        if sid and nm:
            sid_to_name[sid] = nm

    seen_in_log = role_name in set(sid_to_name.values())

    out: list = []
    for rec in records:
        ts = rec.get("ts")
        if not isinstance(ts, str):
            continue
        from_name = rec.get("from_name")
        kind = rec.get("kind") or "direct"
        to_sid = rec.get("to") or ""
        text = rec.get("text") if isinstance(rec.get("text"), str) else ""

        if from_name == role_name:
            direction = "sent"
            peer = "all" if kind == "broadcast" else (sid_to_name.get(to_sid) or "unknown")
        elif kind == "broadcast":
            # Broadcasts fan out to every connected peer; include them in
            # every role's received-stream so the operator sees the same
            # context the role would have seen at its terminal.
            if from_name == role_name:
                continue  # already handled above; defensive
            direction = "received"
            peer = from_name or "unknown"
        elif kind == "direct" and sid_to_name.get(to_sid) == role_name:
            direction = "received"
            peer = from_name or "unknown"
        else:
            continue

        out.append({
            "id": rec.get("msg_id") or "",
            "ts": ts,
            "direction": direction,
            "peer": peer,
            "prefix": _classify(text),
            "body_preview": text[:ROLE_FEED_PREVIEW_CHARS],
        })

    # Records were in arrival order; tail keeps newest LAST (chronological).
    if len(out) > limit:
        out = out[-limit:]
    return out, seen_in_log


# ---------------------------------------------------------------------------
# Theme registry (u14-server-themes). Backs GET /themes.
# Walks bin/dashboard/static/themes/ once at startup (and on SIGHUP), parses
# each subdir's theme.json against the §3 contract, and caches the validated
# list. Invalid themes are skipped with a single stderr warning each; valid
# themes are returned in directory-name order.
# ---------------------------------------------------------------------------

def _validate_theme_json(data: Any, dir_name: str) -> tuple[Optional[dict], Optional[str]]:
    """Validate parsed theme.json against the master-spec §3 contract.

    Returns (theme_object, None) on success, or (None, reason) on failure.
    `theme_object` is the parsed dict with the contract fields kept verbatim;
    extra fields in the source are preserved so the frontend can read any
    forward-compatible additions without a server change.
    """
    if not isinstance(data, dict):
        return None, "theme.json is not a JSON object"
    for f in THEME_REQUIRED_FIELDS:
        if f not in data:
            return None, f"missing required field '{f}'"
    if not isinstance(data["name"], str) or data["name"] != dir_name:
        return None, f"name field does not match dir basename '{dir_name}'"
    if not isinstance(data["display_name"], str) or not data["display_name"]:
        return None, "display_name must be a non-empty string"
    if not isinstance(data["summary"], str) or len(data["summary"]) > THEME_SUMMARY_MAX:
        return None, f"summary must be a string of <= {THEME_SUMMARY_MAX} chars"
    if data["mode"] not in THEME_MODES:
        return None, f"mode must be one of {sorted(THEME_MODES)}"
    if data["default_edge_style"] not in THEME_EDGE_STYLES:
        return None, f"default_edge_style must be one of {sorted(THEME_EDGE_STYLES)}"
    if data["default_token_style"] not in THEME_TOKEN_STYLES:
        return None, f"default_token_style must be one of {sorted(THEME_TOKEN_STYLES)}"
    return data, None


def load_themes(static_dir: Path) -> list:
    """Walk static/themes/, parse each subdir's theme.json, return validated list.

    Emits a single stderr warning per skipped theme (malformed JSON, schema
    miss, name mismatch). The cache is populated by the caller; this function
    has no side effect on it.
    """
    themes_root = static_dir / "themes"
    out: list = []
    if not themes_root.is_dir():
        return out
    try:
        entries = sorted(p for p in themes_root.iterdir() if p.is_dir())
    except OSError as e:
        print(f"themes: cannot list {themes_root}: {e}", file=sys.stderr)
        return out
    for sub in entries:
        # Dir-name discipline: reject anything that does not match the same
        # pattern the URL allows. Avoids surfacing junk dirs like ".DS_Store"
        # or stray staging dirs.
        if not THEME_NAME_RE.match(sub.name):
            print(f"themes: skipping '{sub.name}' (dir name fails THEME_NAME_RE)",
                  file=sys.stderr)
            continue
        tj = sub / "theme.json"
        if not tj.is_file():
            print(f"themes: skipping '{sub.name}' (no theme.json)", file=sys.stderr)
            continue
        try:
            data = json.loads(tj.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            print(f"themes: skipping '{sub.name}' (theme.json unreadable: {e})",
                  file=sys.stderr)
            continue
        obj, why = _validate_theme_json(data, sub.name)
        if obj is None:
            print(f"themes: skipping '{sub.name}' ({why})", file=sys.stderr)
            continue
        out.append(obj)
    return out


def _safe_theme_path(theme: str, filename: str, static_dir: Path) -> Optional[Path]:
    """Resolve /static/themes/<theme>/<filename> or return None.

    Two layers of defence: pattern gates on both <theme> and <filename>, plus
    a realpath-containment check so a basename that survives the pattern but
    escapes via a symlink is still rejected.
    """
    if not THEME_NAME_RE.match(theme):
        return None
    if not THEME_FILE_RE.match(filename):
        return None
    themes_root = (static_dir / "themes").resolve()
    candidate_dir = (static_dir / "themes" / theme).resolve()
    try:
        candidate_dir.relative_to(themes_root)
    except ValueError:
        return None
    if not candidate_dir.is_dir():
        return None
    candidate = (candidate_dir / filename).resolve()
    try:
        candidate.relative_to(candidate_dir)
    except ValueError:
        return None
    return candidate


# ---------------------------------------------------------------------------
# Role state derivation (§4.1).
# ---------------------------------------------------------------------------

def _role_base(name: str) -> str:
    return re.sub(r"\d+$", "", name) or name


def _last_msg_for(role: str, msgs: list) -> Optional[dict]:
    best = None
    for m in msgs:
        if m["from"] == role or m["to"] == role:
            if best is None or m["ts"] > best["ts"]:
                best = m
    return best


def _last_pause_event(role: str, msgs: list) -> Optional[dict]:
    """Return most recent pause:/resume: msg sent *to* this role, or None."""
    best = None
    for m in msgs:
        if m["to"] != role:
            continue
        if m["prefix"] in ("pause", "resume"):
            if best is None or m["ts"] > best["ts"]:
                best = m
    return best


def build_role(active_entry: dict, health: Optional[dict], msgs: list,
               opens: dict, counts_by_role: dict, now: float) -> dict:
    name = active_entry["name"]
    is_orch = (name == "orchestrator")
    role_base = "orchestrator" if is_orch else _role_base(name)
    last_msg = _last_msg_for(name, msgs)
    pause_evt = _last_pause_event(name, msgs)
    # Open questions sent BY this role, oldest first.
    my_opens = sorted(
        ((mid, q) for mid, q in opens.items() if q.get("from") == name),
        key=lambda kv: kv[1]["ts"],
    )
    open_ids = [mid for mid, _ in my_opens]

    # State derivation (priority chain).
    if is_orch:
        state, src, age = "orchestrator", active_entry.get("state_source_override", "active_file"), 0.0
    elif isinstance(health, dict) and health.get("state") == "give-up":
        state, src, age = "give-up", "health", max(0.0, now - float(health.get("last_retry_at") or health.get("since") or now))
    elif isinstance(health, dict) and health.get("state") == "stalled":
        state, src, age = "stalled-api", "health", max(0.0, now - float(health.get("since") or now))
    elif pause_evt and pause_evt["prefix"] == "pause":
        state, src, age = "paused", "bus_pause", max(0.0, now - pause_evt["ts"])
    elif my_opens:
        oldest_ts = my_opens[0][1]["ts"]
        state, src, age = "question", "question_open", max(0.0, now - oldest_ts)
    elif (last_msg is not None and last_msg["ts"] >= now - ACTIVE_RECENT_SEC
          and isinstance(health, dict) and health.get("state") == "active"):
        state, src, age = "active", "bus_recent", max(0.0, now - last_msg["ts"])
    else:
        state, src, age = "idle", "default_idle", (now - last_msg["ts"]) if last_msg else 0.0

    counts = counts_by_role.get(name, {
        "sent_1m": 0, "recv_1m": 0, "sent_total": 0, "recv_total": 0,
    })

    return {
        "name": name,
        "role_base": role_base,
        "pid": active_entry.get("pid"),
        "tmux_window": active_entry.get("tmux_window"),
        "is_orchestrator": is_orch,
        "state": state,
        "state_source": src,
        "state_age_sec": round(age, 2),
        "health": health if isinstance(health, dict) else None,
        "counts": counts,
        "last_msg_ts": last_msg["ts"] if last_msg else None,
        "last_msg_prefix": last_msg["prefix"] if last_msg else None,
        "open_question_ids": open_ids,
    }


def ensure_orchestrator(active: list, team_dir_present: bool) -> tuple[list, bool]:
    """If team_dir is present and roster is non-empty without orchestrator,
    synthesise one so the canvas centre is never empty. Returns (roster, synth)."""
    if not team_dir_present or not active:
        return active, False
    if any(a["name"] == "orchestrator" for a in active):
        return active, False
    synth = {"name": "orchestrator", "pid": None, "tmux_window": None,
             "state_source_override": "synthesized"}
    return [synth] + list(active), True


# ---------------------------------------------------------------------------
# Snapshot assembly.
# ---------------------------------------------------------------------------

def _read_roster_cap(team_dir: Optional[str]) -> int:
    if team_dir:
        path = os.path.join(team_dir, "max-team-size")
        try:
            return int(open(path).read().strip())
        except (OSError, ValueError):
            pass
    env = os.environ.get("MAX_TEAM_SIZE")
    if env:
        try:
            return int(env)
        except ValueError:
            pass
    return 12


def _empty_reason(team_dir: Optional[str], present: bool, active: list) -> tuple:
    """Return (reason_for_ui, is_error) when roster is empty; (None, False) when populated.
    Only is_error=True reasons go into warnings[]; normal startup state does not."""
    if team_dir is None:
        return "No team directory configured (pass --team-dir or set $TEAM_DIR)", True
    if not present:
        return f"Team directory not found: {team_dir}", True
    if not active:
        return "No roles have joined yet. The orchestrator is starting up…", False
    return None, False


def build_snapshot(state: ServerState, now: float) -> dict:
    warnings: list = []
    team_dir = resolve_team_dir(state.team_dir_arg)
    present = bool(team_dir and os.path.isdir(team_dir))

    active = read_active(team_dir, warnings) if present else []
    units = parse_state_md(team_dir, warnings) if present else {
        "counts": {s: 0 for s in _ALLOWED_STATUSES}, "list": [], "timeline": [],
    }
    health = read_health_dir(team_dir, warnings) if present else {}
    msgs, opens, counts_by_role = read_messages(now, state.msg_cache, warnings)

    reason, is_err = _empty_reason(team_dir, present, active)
    if reason and is_err:
        warnings.insert(0, reason)

    roster_entries, _synth = ensure_orchestrator(active, present)
    roster = [
        build_role(entry, health.get(entry["name"]), msgs, opens, counts_by_role, now)
        for entry in roster_entries
    ]

    state_md_mtime = _safe_mtime(os.path.join(team_dir, "state.md")) if present else None
    active_mtime = _safe_mtime(os.path.join(team_dir, "active")) if present else None

    # Decision 2 (u1-spec): annotate the most-recent timeline event with the
    # state.md mtime as ts_real, so the frontend can render "Xm ago" for the
    # head row. Older rows fall back to the date string. Approximation: mtime
    # reflects the latest write to state.md, which is correct for the newest
    # entry and "newer than reality" for older ones — hence head-only.
    if units["timeline"] and state_md_mtime:
        units["timeline"][0]["ts_real"] = state_md_mtime

    # run_id: basename minus leading .team- ; legacy .team => null.
    run_id = None
    if team_dir:
        base = os.path.basename(team_dir.rstrip("/"))
        if base.startswith(".team-"):
            run_id = base[len(".team-"):]
        elif base == ".team":
            run_id = None

    # elapsed: max of (now - state_md_mtime) and (now - oldest health "since"),
    # floored to 0. Falls back to server uptime if neither is available.
    candidates = []
    if state_md_mtime:
        candidates.append(now - state_md_mtime)
    health_sinces = [
        h.get("since") for h in health.values()
        if isinstance(h, dict) and isinstance(h.get("since"), (int, float))
    ]
    if health_sinces:
        candidates.append(now - min(health_sinces))
    elapsed = int(max(candidates)) if candidates else int(now - state.started_ts)
    elapsed = max(0, elapsed)

    return {
        "schema_version": SCHEMA_VERSION,
        "ok": True,
        "team_dir": team_dir,
        "team_dir_present": present,
        "now_ts": round(now, 3),
        "server_started_ts": round(state.started_ts, 3),
        "run": {
            "run_id": run_id,
            "elapsed_seconds": elapsed,
            "roster_count": len(active),  # real roles only; synthetic orchestrator not counted
            "roster_cap": _read_roster_cap(team_dir),
            "roster_cap_kind": "soft",
            "state_md_mtime": state_md_mtime,
            "active_file_mtime": active_mtime,
        },
        "roster": roster,
        "units": {"counts": units["counts"], "list": units["list"]},
        "messages": msgs[-SERIALIZE_MAX:],
        "timeline": units["timeline"],
        "empty_reason": reason,
        "warnings": warnings,
    }


# ---------------------------------------------------------------------------
# /chat surface (u30). Backs the communicator role's push surface.
# All file reads/writes use realpath containment under $TEAM_DIR/comm/.
# ---------------------------------------------------------------------------

def _comm_dir(team_dir: Optional[str]) -> Optional[Path]:
    if not team_dir:
        return None
    return Path(team_dir) / "comm"


def _safe_comm_path(team_dir: Optional[str], filename: str) -> Optional[Path]:
    """Resolve $TEAM_DIR/comm/<filename> or return None.

    Two layers of defence: filename must not contain `/`, `\\`, NUL, or `..`
    components, and the resolved realpath must stay under $TEAM_DIR/comm/. A
    symlinked entry that points elsewhere is rejected.
    """
    if team_dir is None:
        return None
    if not filename or any(b in filename for b in ("/", "\\", "\x00")):
        return None
    if filename in (".", "..") or filename.startswith("."):
        # The four files the communicator owns all begin with a letter; reject
        # dotfiles wholesale rather than carry an allow-list mismatch.
        return None
    try:
        root = (Path(team_dir) / "comm").resolve()
    except OSError:
        return None
    try:
        candidate = (Path(team_dir) / "comm" / filename).resolve()
    except OSError:
        return None
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return candidate


def _parse_chat_since(raw: Optional[str]) -> tuple[Optional[str], Optional[Any]]:
    """Validate `?since=<x>` and return ("ts", float) or ("msgid", str) or
    (None, None) when the cursor is empty/missing. Raises ValueError on a
    malformed cursor so the handler can 400."""
    if raw is None or raw == "":
        return None, None
    if CHAT_MSGID_RE.match(raw):
        return "msgid", raw
    ts = _parse_iso(raw)
    if ts is not None:
        return "ts", ts
    raise ValueError(f"malformed since cursor: {raw!r}")


def _read_chat_entries(team_dir: Optional[str], cursor_kind: Optional[str],
                       cursor_val: Any, warnings: list) -> list:
    """Project $TEAM_DIR/comm/conversation.jsonl, filter by cursor, cap to
    CHAT_MAX_ENTRIES from the tail. Returns [] when the file is absent."""
    path = _safe_comm_path(team_dir, "conversation.jsonl")
    if path is None or not path.is_file():
        return []
    out: list = []
    try:
        with path.open("r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    warnings.append("conversation.jsonl: skipped malformed line")
                    continue
                if not isinstance(rec, dict):
                    continue
                out.append(rec)
    except OSError as e:
        warnings.append(f"conversation.jsonl not readable: {e}")
        return []

    if cursor_kind == "ts":
        out = [r for r in out if (_parse_iso(r.get("ts")) or 0.0) > cursor_val]
    elif cursor_kind == "msgid":
        # Strictly after the entry whose msg_id matches; if no such entry,
        # return empty (the cursor refers to an entry this server hasn't
        # written, so by definition nothing newer than it exists here).
        idx = None
        for i, r in enumerate(out):
            if r.get("msg_id") == cursor_val:
                idx = i
                break
        out = out[idx + 1:] if idx is not None else []

    if len(out) > CHAT_MAX_ENTRIES:
        out = out[-CHAT_MAX_ENTRIES:]
    return out


def _read_open_question(team_dir: Optional[str], warnings: list) -> dict:
    path = _safe_comm_path(team_dir, "open-question.json")
    if path is None or not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        warnings.append(f"open-question.json not readable: {e}")
        return {}
    return data if isinstance(data, dict) else {}


def _read_chat_queue(team_dir: Optional[str], warnings: list) -> list:
    path = _safe_comm_path(team_dir, "question-queue.jsonl")
    if path is None or not path.is_file():
        return []
    out: list = []
    try:
        with path.open("r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    warnings.append("question-queue.jsonl: skipped malformed line")
                    continue
                out.append(rec)
    except OSError as e:
        warnings.append(f"question-queue.jsonl not readable: {e}")
        return []
    return out


def _now_iso_utc() -> str:
    return datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def _thread_id_for(team_dir: Optional[str]) -> Optional[str]:
    if not team_dir:
        return None
    base = os.path.basename(team_dir.rstrip("/"))
    if base.startswith(".team-"):
        return base[len(".team-"):]
    return None


def _validate_chat_post(body: Any) -> tuple[Optional[dict], Optional[str]]:
    """Return (normalized_entry, None) on success or (None, reason)."""
    if not isinstance(body, dict):
        return None, "body must be a JSON object"
    author = body.get("author_name")
    text = body.get("body")
    if not isinstance(author, str) or not author.strip():
        return None, "missing or empty author_name"
    if not isinstance(text, str) or text == "":
        return None, "missing or empty body"
    if len(text.encode("utf-8")) > CHAT_BODY_MAX:
        return None, f"body exceeds {CHAT_BODY_MAX} bytes"
    addressed_to = body.get("addressed_to")
    if addressed_to is not None:
        if not isinstance(addressed_to, str) or not CHAT_ADDRESSED_TO_RE.match(addressed_to):
            return None, "addressed_to must match operator|orchestrator|role:<name>"
    # Path-traversal defence: reject NUL or backslash anywhere in stringy fields
    # so a downstream tool that mistakes one for a path separator stays safe.
    for k in ("author_name", "body", "addressed_to"):
        v = body.get(k)
        if isinstance(v, str) and ("\x00" in v):
            return None, f"NUL byte in {k}"
    return {
        "author_name": author,
        "body": text,
        "addressed_to": addressed_to,
    }, None


def _append_inbound(team_dir: str, entry: dict, warnings: list) -> Optional[dict]:
    """Append one JSONL entry to $TEAM_DIR/comm/inbound.jsonl and return the
    written record. Creates the comm/ dir (mode 0700) if absent."""
    comm = _comm_dir(team_dir)
    if comm is None:
        return None
    try:
        comm.mkdir(parents=True, exist_ok=True, mode=0o700)
    except OSError as e:
        warnings.append(f"comm/ not creatable: {e}")
        return None
    path = _safe_comm_path(team_dir, "inbound.jsonl")
    if path is None:
        return None
    record = {
        "ts": _now_iso_utc(),
        "thread_id": _thread_id_for(team_dir),
        "author_type": "operator",
        "author_name": entry["author_name"],
        "prefix": None,
        "msg_id": None,
        "in_reply_to": None,
        "addressed_to": entry.get("addressed_to"),
        "unit": None,
        "body": entry["body"],
    }
    try:
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, separators=(",", ":"), ensure_ascii=False))
            fh.write("\n")
    except OSError as e:
        warnings.append(f"inbound.jsonl not writable: {e}")
        return None
    return record


# ---------------------------------------------------------------------------
# HTTP handler.
# ---------------------------------------------------------------------------

def _safe_static_path(name: str, static_dir: Path) -> Optional[Path]:
    if name not in STATIC_ALLOWLIST:
        return None
    return static_dir / name


def _safe_img_path(basename: str, static_dir: Path) -> Optional[Path]:
    """Resolve /static/img/<basename> safely or return None.

    Refuses anything that does not match IMG_BASENAME_RE, and re-checks the
    *resolved* path stays under static_dir/img — so a basename that survives
    the pattern but somehow escapes via a symlink is still rejected.
    """
    if not IMG_BASENAME_RE.match(basename):
        return None
    img_dir = (static_dir / "img").resolve()
    candidate = (static_dir / "img" / basename).resolve()
    try:
        candidate.relative_to(img_dir)
    except ValueError:
        return None
    return candidate


def _mime_for(path: Path) -> str:
    return MIME_BY_EXT.get(path.suffix.lower(), "application/octet-stream")


def make_handler(state: ServerState):

    class Handler(BaseHTTPRequestHandler):
        server_version = "B11Dashboard/1.0"

        def _send_json(self, payload: Any, status: int = 200) -> None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "null")
            self.end_headers()
            self.wfile.write(body)

        def _send_file(self, path: Path, content_type: str, cache: str) -> None:
            try:
                body = path.read_bytes()
            except OSError:
                self._send_json({"error": "not found"}, status=404)
                return
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            # Parse + sanitize the path before any filesystem lookup.
            raw = urlsplit(self.path).path
            if any(bad in raw for bad in ("..", "%2e", "%2E", "\\", "\x00")):
                self._send_json({"error": "not found"}, status=404)
                return

            if raw in ("/", "/index.html"):
                self._send_file(state.index_html, "text/html; charset=utf-8", "no-store")
                return
            if raw == "/state.json":
                snapshot = build_snapshot(state, time.time())
                self._send_json(snapshot)
                return
            if raw == "/healthz":
                self._send_json({"ok": True})
                return
            if raw == "/themes":
                self._send_json({
                    "schema_version": SCHEMA_VERSION,
                    "themes": state.themes,
                })
                return
            if raw == "/chat":
                team_dir = resolve_team_dir(state.team_dir_arg)
                qs = parse_qs(urlsplit(self.path).query)
                raw_since = qs.get("since", [None])[0]
                try:
                    cursor_kind, cursor_val = _parse_chat_since(raw_since)
                except ValueError as e:
                    self._send_json({"error": str(e)}, status=400)
                    return
                warnings: list = []
                entries = _read_chat_entries(
                    team_dir, cursor_kind, cursor_val, warnings
                )
                self._send_json({
                    "thread_id": _thread_id_for(team_dir),
                    "schema_version": SCHEMA_VERSION,
                    "since": raw_since or "",
                    "entries": entries,
                })
                return
            if raw == "/chat/open-question":
                team_dir = resolve_team_dir(state.team_dir_arg)
                warnings = []
                self._send_json(_read_open_question(team_dir, warnings))
                return
            if raw == "/chat/queue":
                team_dir = resolve_team_dir(state.team_dir_arg)
                warnings = []
                self._send_json(_read_chat_queue(team_dir, warnings))
                return
            if raw.startswith("/role-feed/"):
                name = raw[len("/role-feed/"):]
                if not name or "/" in name or not ROLE_NAME_RE.match(name):
                    self._send_json({"error": "invalid role name"}, status=400)
                    return
                qs = parse_qs(urlsplit(self.path).query)
                limit = ROLE_FEED_DEFAULT
                limit_raw = qs.get("limit", [None])[0]
                if limit_raw is not None:
                    try:
                        limit = int(limit_raw)
                    except ValueError:
                        limit = ROLE_FEED_DEFAULT
                limit = max(1, min(limit, ROLE_FEED_MAX))

                warnings: list = []
                log_path = _resolve_log_path()
                messages, seen_in_log = read_role_feed(name, limit, log_path, warnings)

                if not seen_in_log:
                    # Role may be freshly joined and not yet sent anything.
                    team_dir = resolve_team_dir(state.team_dir_arg)
                    active = read_active(team_dir, []) if team_dir else []
                    if not any(a.get("name") == name for a in active):
                        self._send_json({"error": "unknown role"}, status=404)
                        return

                self._send_json({
                    "role": name,
                    "schema_version": SCHEMA_VERSION,
                    "messages": messages,
                })
                return
            if raw.startswith("/static/"):
                sub = raw[len("/static/"):]
                if not sub:
                    self._send_json({"error": "not found"}, status=404)
                    return
                # /static/img/<basename>: separate, tighter allowlist by
                # extension + realpath containment, so we do not need to
                # enumerate every committed PNG by name.
                if sub.startswith("img/"):
                    basename = sub[len("img/"):]
                    if "/" in basename or not basename:
                        self._send_json({"error": "not found"}, status=404)
                        return
                    path = _safe_img_path(basename, state.static_dir)
                    if path is None or not path.is_file():
                        self._send_json({"error": "not found"}, status=404)
                        return
                    self._send_file(path, _mime_for(path), "max-age=300")
                    return
                # /static/themes/<theme>/<file>: theme-pack asset, gated by
                # dir + file pattern allowlists AND a realpath-containment
                # check so a basename surviving the pattern via a symlink
                # cannot escape the theme dir.
                if sub.startswith("themes/"):
                    rest = sub[len("themes/"):]
                    if "/" not in rest:
                        self._send_json({"error": "not found"}, status=404)
                        return
                    theme, _, filename = rest.partition("/")
                    if "/" in filename or not filename:
                        self._send_json({"error": "not found"}, status=404)
                        return
                    path = _safe_theme_path(theme, filename, state.static_dir)
                    if path is None or not path.is_file():
                        self._send_json({"error": "not found"}, status=404)
                        return
                    self._send_file(path, _mime_for(path), "max-age=300")
                    return
                if "/" in sub:
                    self._send_json({"error": "not found"}, status=404)
                    return
                path = _safe_static_path(sub, state.static_dir)
                if path is None or not path.is_file():
                    self._send_json({"error": "not found"}, status=404)
                    return
                self._send_file(path, _mime_for(path), "max-age=60")
                return

            self._send_json({"error": "not found"}, status=404)

        def do_POST(self) -> None:
            raw = urlsplit(self.path).path
            if any(bad in raw for bad in ("..", "%2e", "%2E", "\\", "\x00")):
                self._send_json({"error": "not found"}, status=404)
                return
            if raw != "/chat":
                self._send_json({"error": "not found"}, status=404)
                return

            # Length gate first: refuse to read past the cap. Content-Length is
            # advisory; if absent we still cap the read so a chunked or oversized
            # body cannot stream past the limit.
            try:
                clen = int(self.headers.get("Content-Length", "0") or "0")
            except ValueError:
                self._send_json({"error": "invalid Content-Length"}, status=400)
                return
            if clen < 0 or clen > CHAT_BODY_MAX + 1024:
                self._send_json(
                    {"error": f"body exceeds {CHAT_BODY_MAX} bytes"}, status=400
                )
                return
            try:
                payload = self.rfile.read(min(clen, CHAT_BODY_MAX + 1024)) if clen else b""
            except OSError:
                self._send_json({"error": "body read failed"}, status=400)
                return
            if not payload:
                self._send_json({"error": "empty body"}, status=400)
                return
            try:
                parsed = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                self._send_json({"error": "malformed JSON"}, status=400)
                return
            entry, why = _validate_chat_post(parsed)
            if entry is None:
                self._send_json({"error": why}, status=400)
                return

            team_dir = resolve_team_dir(state.team_dir_arg)
            if not team_dir:
                self._send_json({"error": "no team dir configured"}, status=400)
                return
            warnings: list = []
            record = _append_inbound(team_dir, entry, warnings)
            if record is None:
                msg = warnings[-1] if warnings else "append failed"
                self._send_json({"error": msg}, status=500)
                return
            self._send_json({"ok": True, "ts": record["ts"]}, status=202)

        def log_message(self, fmt, *args) -> None:
            # Quiet by default; stderr would clutter the tmux pane.
            return

    return Handler


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="dashboard.sh",
        description="A read-only web dashboard for a live orchestrator run.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--team-dir", metavar="DIR", default=None,
                   help="team state directory (default: $TEAM_DIR, then "
                        "$(pwd)/.team, then newest .team-* in cwd)")
    p.add_argument("--port", type=int, default=0,
                   help="TCP port to bind (default: 0 = pick a free port)")
    p.add_argument("--host", default="127.0.0.1",
                   help="bind address (default: 127.0.0.1; only loopback accepted)")
    p.add_argument("--open", action="store_true",
                   help="attempt to open the URL in the default browser")
    p.add_argument("--no-banner", action="store_true",
                   help="suppress the startup banner")
    return p


def main(argv: Optional[list] = None) -> int:
    args = _build_parser().parse_args(argv)

    if args.host not in LOOPBACK_HOSTS:
        print("refusing non-loopback bind; B4 is the Tailscale story", file=sys.stderr)
        return 2

    # server.py lives at bin/dashboard/server/server.py; static + index.html
    # are siblings of the server/ dir under bin/dashboard/.
    web_root = Path(__file__).resolve().parent.parent
    static_dir = web_root / "static"
    index_html = web_root / "index.html"

    msg_cache = MessageCache()
    started_ts = time.time()

    server_state = ServerState(
        team_dir_arg=args.team_dir,
        static_dir=static_dir,
        index_html=index_html,
        started_ts=started_ts,
        msg_cache=msg_cache,
        themes=load_themes(static_dir),
    )

    try:
        httpd = HTTPServer((args.host, args.port), make_handler(server_state))
    except OSError as e:
        print(f"bind failed on {args.host}:{args.port}: {e}; try --port 0",
              file=sys.stderr)
        return 3

    port = httpd.server_address[1]
    resolved = resolve_team_dir(args.team_dir)
    url = f"http://{args.host}:{port}/"

    if not args.no_banner:
        print(f"dashboard: {url}  team-dir={resolved or 'none'}", flush=True)

    if args.open:
        try:
            import webbrowser
            webbrowser.open(url)
        except Exception:
            pass

    # serve_forever() runs on the main thread and only checks the shutdown
    # flag between poll_interval ticks. Calling httpd.shutdown() directly from
    # a signal handler would deadlock: shutdown() blocks on an event that the
    # serve loop sets, but the serve loop is the very thread the handler has
    # paused. So we hand the shutdown off to a daemon thread; the signal
    # handler returns immediately, serve_forever resumes, picks up the flag on
    # its next tick, and exits cleanly.
    def _stop(signum, frame):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    # SIGHUP rebuilds the theme cache so an operator can drop a new theme into
    # bin/dashboard/static/themes/ and reload without bouncing the server. The
    # rebuild runs on a daemon thread to keep the signal handler short.
    def _reload_themes(signum, frame):
        def _do():
            new_themes = load_themes(static_dir)
            server_state.themes = new_themes
            print(f"themes: reloaded ({len(new_themes)} theme(s))", file=sys.stderr)
        threading.Thread(target=_do, daemon=True).start()

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)
    # SIGHUP is POSIX-only; guard for portability even though we only ship
    # on Linux today.
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, _reload_themes)

    try:
        httpd.serve_forever()
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:
        print(f"dashboard: uncaught exception: {e}", file=sys.stderr)
        sys.exit(1)
