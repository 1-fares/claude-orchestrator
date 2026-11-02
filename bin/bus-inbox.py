#!/usr/bin/env python3
"""bus-inbox: one long-lived bus listener per role, and a blocking reader that wakes the role ONLY when
a line arrives, at a heartbeat, or when the listener is dead.

  bus-inbox.py start  <name>           start the listener (idempotent; a second start is a no-op)
  bus-inbox.py wait   <name> [max_s]   block until new inbox lines (print them, exit 0), the heartbeat
                                       (exit 0, one HEARTBEAT line) or a dead listener (exit 2); exit 3 =
                                       another reader is already waiting (this one read nothing); exit 4 =
                                       stdout failed (cursor NOT moved). At-least-once: a crash between the
                                       flush and the cursor write repeats those lines to the next reader.
  bus-inbox.py status <name>           exit 0 alive, 2 dead

Why: a Monitor is capped at 30 min, so every idle role woke 48 times a day to re-arm it, and each re-arm
took its name off the bus for a moment (a send in that moment is refused with unknown_peer and lost).
Here the listener is never restarted on a wake; only the reader is. The inbox is a file with a byte
cursor, so a line that lands between two readers is returned by the next one.

Layout under $BUS_INBOX_DIR (default $TEAM_DIR/bus-inbox): <name>.log inbox, <name>.cursor bytes
consumed, <name>.pid "<pump pid> <client pid>", <name>.lock flock shared by writer and reader.

Process shape: `start` runs a detached PUMP (this file, `_pump`), which runs client.py with its stdout
on a pipe and appends each line to the inbox under the lock. The client gets PDEATHSIG, so it cannot
outlive the pump. The pump ends on the client's EOF. client.py exits by itself when the role's Claude
Code process dies (its owner watch, 10 s), so nothing outlives the role. Both are keyed to the role's
CC pid (INTER_SESSION_PPID_OVERRIDE / _OWNER_PID, resolved here before the launching shell exits), so
send.py and list.py --self from the role find the listener, and a Monitor still armed for the same
role makes `start` fail loud ("another monitor for this session is already running").

Size: once everything is read (cursor == size) and the inbox is over BUS_INBOX_CAP_BYTES (1 MiB), the
pump rotates it to <name>.log.1 (one generation) before the next append. Unread lines are never
rotated away; an unread inbox grows only while its role is alive and not reading.
"""
import fcntl, os, re, signal, subprocess, sys, time
from pathlib import Path

IS_BIN = Path(os.environ.get("IS_BIN") or Path.home() / ".claude/skills/is/bin")
# A burst becomes one wake: after the first new byte, wait until the inbox has been quiet for SETTLE_S
# (at most SETTLE_MAX_S). A fixed 2 s sleep split a 3-message burst 2+1 (bus-send takes ~1 s per call).
SETTLE_S = float(os.environ.get("BUS_INBOX_SETTLE_S") or 2)
SETTLE_MAX_S = float(os.environ.get("BUS_INBOX_SETTLE_MAX_S") or 15)
CAP = int(os.environ.get("BUS_INBOX_CAP_BYTES") or 1 << 20)
START_WAIT_S = float(os.environ.get("BUS_INBOX_START_WAIT_S") or 3)


def _dir() -> Path:
    base = os.environ.get("BUS_INBOX_DIR") or (
        str(Path(os.environ["TEAM_DIR"]) / "bus-inbox") if os.environ.get("TEAM_DIR") else "")
    if not base:
        sys.exit("bus-inbox: set BUS_INBOX_DIR or TEAM_DIR")
    d = Path(base)
    d.mkdir(parents=True, exist_ok=True)
    return d


class P:
    def __init__(self, name):
        d = _dir()
        self.inbox, self.cursor = d / f"{name}.log", d / f"{name}.cursor"
        self.pid, self.lock, self.err = d / f"{name}.pid", d / f"{name}.lock", d / f"{name}.pump.err"


class Locked:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.fd = os.open(self.path, os.O_WRONLY | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)

    def __exit__(self, *a):
        os.close(self.fd)


def _cc_pid() -> int:
    """shared.find_cc_ancestor_pid's rule, read from /proc: that one needs psutil, which only the skill
    venv has, and returns -1 SILENTLY under the system python."""
    pid, seen = os.getppid(), set()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        try:
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            stat = Path(f"/proc/{pid}/stat").read_text()
        except OSError:
            return -1
        exe = os.path.basename(argv[0].decode(errors="replace")).lower() if argv and argv[0] else ""
        rest = b" ".join(argv[1:]).decode(errors="replace").lower()
        if exe == "claude" or exe.startswith("claude-"):
            return pid
        if exe in ("node", "node.exe") and ("/claude" in rest or "claude-code" in rest or "/.claude/" in rest):
            return pid
        pid = int(stat.rsplit(")", 1)[1].split()[1])
    return -1


def _argv(pid: int):
    try:
        if Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] == "Z":
            return None
        return [x.decode(errors="replace") for x in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")]
    except (OSError, IndexError):
        return None


def _alive(p: P, name: str):
    """(pump, client) if BOTH are alive and are what the pidfile says (no recycled-pid match), else None."""
    try:
        pump, client = (int(x) for x in p.pid.read_text().split())
    except (OSError, ValueError):
        return None
    a, c = _argv(pump), _argv(client)
    if not a or not c:
        return None
    if not (any(x.endswith("bus-inbox.py") for x in a) and "_pump" in a and name in a):
        return None
    if not (any(x.endswith("client.py") for x in c) and "--name" in c and c[c.index("--name") + 1] == name):
        return None
    return pump, client


def _append(p: P, data: bytes):
    with Locked(p.lock):
        size = p.inbox.stat().st_size if p.inbox.exists() else 0
        cur = int(p.cursor.read_text() or 0) if p.cursor.exists() else 0
        if size > CAP and cur >= size:
            os.replace(p.inbox, str(p.inbox) + ".1")
            p.cursor.write_text("0")
        with open(p.inbox, "ab") as f:
            f.write(data)


# SELF-RELOAD. The pump is a long-lived per-role daemon, so a committed bus-inbox.py must reach it
# without a hand restart. The rules of bin/lib/self-reload.sh, in python: debounce on FILE AGE, compile()
# before exec, re-exec with the ORIGINAL argv (inherited-* flags stripped first, so the second reload is
# as clean as the first) and the unchanged environment, carry the client's stdout pipe across the exec
# (PEP 446 would close it), and let the NEW image write the audit line to the same self-reload.log.
# The client is NOT restarted: the name never leaves the bus, so nothing is refused while it happens.
# Nothing is lost in the pipe either: the pump reads the raw fd and execs only with no partial line
# held, so every byte the old image took off the pipe is already in the inbox.
# bus-inbox.py imports nothing from bin/ (stdlib only), so this file is its whole code set.
SELF_RELOAD_MIN_AGE = float(os.environ.get("SELF_RELOAD_MIN_AGE") or 10)
_INH = ("--inherited-listener-fd", "--inherited-listener-pid")


def _sr_stat():
    try:
        st = os.stat(os.path.abspath(__file__))
        return (st.st_size, st.st_mtime_ns)
    except OSError:
        return None


def _plog(msg: str):
    sys.stderr.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} pump[{os.getpid()}] {msg}\n")
    sys.stderr.flush()


def _write_reload_audit():
    """Written by the NEW image only, so it records a reload that happened. The line contains "re-exec"
    and ENDS with the absolute script path, so a reader can tell which file was reloaded and when."""
    td = os.environ.get("TEAM_DIR")
    if not td:
        _plog("self-reload: TEAM_DIR unset; reload not recorded")
        return
    try:
        d = Path(td) / "audit" / "watchdog"
        d.mkdir(parents=True, exist_ok=True)
        with open(d / "self-reload.log", "a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} self-reload: bus-inbox pump "
                     f"pid={os.getpid()} re-exec CONFIRMED by the new image; re-exec {os.path.abspath(__file__)}\n")
    except OSError as exc:
        _plog(f"self-reload: audit write failed ({exc!r})")


def _pump(argv) -> int:
    name, cc = argv[0], int(argv[1])
    inh_fd = int(argv[argv.index("--inherited-listener-fd") + 1]) if "--inherited-listener-fd" in argv else None
    inh_pid = int(argv[argv.index("--inherited-listener-pid") + 1]) if "--inherited-listener-pid" in argv else None
    p = P(name)
    if inh_fd is not None and inh_pid is not None:
        # ADOPT our own claim: same pid, same client, same pipe. Never "already running" against ourselves.
        fd, cpid = inh_fd, inh_pid
        _write_reload_audit()
        _plog(f"self-reload: adopted client {cpid} on fd {fd}")
    else:
        env = dict(os.environ, INTER_SESSION_PPID_OVERRIDE=str(cc), INTER_SESSION_OWNER_PID=str(cc),
                   PYTHONUNBUFFERED="1")

        def _die_with_pump():
            import ctypes
            ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG

        child = subprocess.Popen([sys.executable, str(IS_BIN / "client.py"), "--name", name],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 env=env, preexec_fn=_die_with_pump)
        fd, cpid = os.dup(child.stdout.fileno()), child.pid
        child.stdout.close()
    p.pid.write_text(f"{os.getpid()} {cpid}\n")
    signal.signal(signal.SIGTERM, lambda *_: os.kill(cpid, signal.SIGTERM))
    import select
    baseline, partial = _sr_stat(), b""
    while True:
        r, _, _ = select.select([fd], [], [], 2.0)
        if r:
            data = os.read(fd, 65536)
            if not data:
                break
            partial += data
            cut = partial.rfind(b"\n")
            if cut >= 0:
                _append(p, partial[:cut + 1])
                partial = partial[cut + 1:]
            continue
        cur = _sr_stat()
        if partial or cur is None or cur == baseline or time.time() - cur[1] / 1e9 < SELF_RELOAD_MIN_AGE:
            continue
        try:
            src = open(os.path.abspath(__file__), "rb").read()
            compile(src, os.path.abspath(__file__), "exec")
        except (OSError, SyntaxError, ValueError) as exc:
            _plog(f"self-reload: new file fails to compile ({exc!r}); staying on old code")
            baseline = cur
            continue
        clean, skip = [], False
        for a in argv:
            if skip:
                skip = False
                continue
            if a in _INH:
                skip = True
                continue
            clean.append(a)
        try:
            os.set_inheritable(fd, True)
            _plog("self-reload: file changed and settled; re-exec")
            os.execv(sys.executable, [sys.executable, os.path.abspath(__file__), "_pump", *clean,
                                      "--inherited-listener-fd", str(fd), "--inherited-listener-pid", str(cpid)])
        except OSError as exc:
            _plog(f"self-reload: exec FAILED ({exc!r}); continuing on the old code")
            baseline = cur
    if partial:
        _append(p, partial + b"\n")
    try:
        _, status = os.waitpid(cpid, 0)
        rc = os.waitstatus_to_exitcode(status)
    except ChildProcessError:
        rc = "unknown"
    _append(p, f"[bus-inbox] listener for {name} exited rc {rc}\n".encode())
    return 0


def _start_failure_lines(new: bytes) -> str:
    """The lines that mean OUR listener did not come up, and only those.

    Only two sources count: the pump's own exit line ("[bus-inbox] listener for <n> exited ...") and a
    notice the CLIENT prints about itself -- "[inter-session] <notice>" (another monitor already running,
    hello rejected, name taken / renamed, identity check failed, owner gone, dependencies missing). A
    MESSAGE is "[inter-session msg=<id> ...] <text>" and its overflow line "[inter-session msg=<id> cont]";
    a message saying "rejected" or "already running" is mail, never a start failure. The first seconds
    after a start are exactly when retrying senders deliver, so matching message text made `start`
    report "did not start" on a healthy listener and left the role unarmed.
    """
    bad = []
    for line in new.split(b"\n"):
        if line.startswith(b"[inter-session msg="):
            continue
        if line.startswith(b"[bus-inbox] listener for ") or line.startswith(b"[inter-session] "):
            bad.append(line.decode(errors="replace"))
    return "\n".join(bad)


def start(name: str) -> int:
    p = P(name)
    with Locked(str(p.lock) + ".start"):          # two concurrent starts give ONE listener
        live = _alive(p, name)
        if live:
            print(f"bus-inbox: listener for {name} already running (pump {live[0]}, client {live[1]})")
            return 0
        cc = int(os.environ.get("BUS_INBOX_CC_PID") or _cc_pid())
        if cc <= 0:
            print("bus-inbox: no Claude Code ancestor; refusing (the listener would have no owner)",
                  file=sys.stderr)
            return 1
        with Locked(p.lock):
            if not p.cursor.exists():   # first start: an old inbox is not replayed as new mail
                p.cursor.write_text(str(p.inbox.stat().st_size if p.inbox.exists() else 0))
            mark = p.inbox.stat().st_size if p.inbox.exists() else 0
        p.pid.unlink(missing_ok=True)
        with open(p.err, "ab") as err:
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "_pump", name, str(cc)],
                             stdin=subprocess.DEVNULL, stdout=err, stderr=err, start_new_session=True)
        deadline = time.monotonic() + START_WAIT_S
        while time.monotonic() < deadline:
            time.sleep(0.25)
            new = b""
            if p.inbox.exists():
                with open(p.inbox, "rb") as f:
                    f.seek(mark)
                    new = f.read()
            bad = _start_failure_lines(new)
            if bad:
                print(f"bus-inbox: listener for {name} did not start:\n{bad}", file=sys.stderr)
                return 1
        live = _alive(p, name)
        if not live:
            print(f"bus-inbox: listener for {name} not alive after {START_WAIT_S:g}s; see {p.err}",
                  file=sys.stderr)
            return 1
        print(f"bus-inbox: listener for {name} started (pump {live[0]}, client {live[1]}, "
              f"owner cc {cc}, inbox {p.inbox})")
        return 0


_READER_FD = None


def wait(name: str, max_s: float) -> int:
    """Block for new lines; AT-LEAST-ONCE: the cursor moves only after the lines were written AND flushed.

    The cursor used to move BEFORE the print, so a failed write (closed pipe,
    full disk, a locale that cannot encode the text, a kill between the two) consumed lines nobody saw.
    Now the bytes go to stdout's buffer unencoded, are flushed, and only then is the cursor advanced; a
    crash between flush and cursor write shows those lines AGAIN to the next reader (a duplicate, never a
    loss). And ONE reader per name: a second `wait` (an accidental double arm) exits at once, rc 3, having
    read nothing -- two readers used to split the inbox between two outputs.
    """
    global _READER_FD
    p = P(name)
    _READER_FD = os.open(str(p.lock) + ".reader", os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(_READER_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(f"[bus-inbox] READER ALREADY RUNNING for {name}: another `wait` holds it; this one read "
              f"nothing. Do not re-arm until that one completes (`bus-inbox.py status {name}`).")
        return 3
    t0 = time.monotonic()
    while True:
        out = None
        with Locked(p.lock):
            cur = int(p.cursor.read_text() or 0) if p.cursor.exists() else 0
            size = p.inbox.stat().st_size if p.inbox.exists() else 0
            pending = size > cur
        if pending:
            t_first, last_size, t_last = time.monotonic(), size, time.monotonic()
            while time.monotonic() - t_last < SETTLE_S and time.monotonic() - t_first < SETTLE_MAX_S:
                time.sleep(0.25)
                now_size = p.inbox.stat().st_size if p.inbox.exists() else 0
                if now_size != last_size:
                    last_size, t_last = now_size, time.monotonic()
            with Locked(p.lock):
                cur = int(p.cursor.read_text() or 0) if p.cursor.exists() else 0
                with open(p.inbox, "rb") as f:
                    f.seek(cur)
                    chunk = f.read()
                end = chunk.rfind(b"\n")
                if end >= 0:             # whole lines only
                    out = chunk[:end + 1]
        if out:
            try:
                sys.stdout.buffer.write(out)
                sys.stdout.buffer.flush()
            except (OSError, ValueError) as exc:
                sys.stderr.write(f"[bus-inbox] could not deliver {len(out)} bytes ({exc!r}); cursor NOT "
                                 f"moved, the next reader gets them\n")
                sys.stderr.flush()
                os._exit(4)   # not `return`: the interpreter's exit flush would fail on the same stdout -> rc 120
            with Locked(p.lock):          # the pump never rotates while cur < size, so cur is still valid
                p.cursor.write_text(str(cur + len(out)))
            if not _alive(p, name):   # the lines may include the pump's own exit line: say DEAD, rc 2
                print(f"[bus-inbox] LISTENER DEAD for {name}: run `bus-inbox.py start {name}`, re-arm "
                      f"wait, and send a status: line to the orchestrator")
                sys.stdout.flush()
                return 2
            return 0
        if not _alive(p, name):
            print(f"[bus-inbox] LISTENER DEAD for {name}: run `bus-inbox.py start {name}`, re-arm wait, "
                  f"and send a status: line to the orchestrator")
            return 2
        if time.monotonic() - t0 >= max_s:
            print(f"[bus-inbox] HEARTBEAT {name}: no message in {max_s:g}s, listener alive")
            return 0
        time.sleep(1)


def status(name: str) -> int:
    p = P(name)
    live = _alive(p, name)
    size = p.inbox.stat().st_size if p.inbox.exists() else 0
    cur = p.cursor.read_text().strip() if p.cursor.exists() else "-"
    reader = "none"
    fd = os.open(str(p.lock) + ".reader", os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        reader = "armed"            # a `wait` holds the reader lock
    finally:
        os.close(fd)
    print(f"name={name} listener={'pump %d client %d' % live if live else 'DEAD'} reader={reader} "
          f"inbox_bytes={size} cursor={cur}")
    return 0 if live else 2


def main() -> int:
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == "_pump":
        return _pump(a[1:])
    if len(a) < 2 or a[0] not in ("start", "wait", "status"):
        print(__doc__, file=sys.stderr)
        return 64
    # A name is what the bus accepts, nothing else: `bus-inbox.py start --help`
    # once wrote state files for a role called "--help".
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", a[1]):
        print(f"[bus-inbox] invalid name {a[1]!r}: must match ^[a-z0-9][a-z0-9-]{{0,39}}$", file=sys.stderr)
        print(__doc__, file=sys.stderr)
        return 64
    if a[0] == "start":
        return start(a[1])
    if a[0] == "wait":
        return wait(a[1], float(a[2]) if len(a) > 2 else 7200)
    return status(a[1])


if __name__ == "__main__":
    sys.exit(main())
