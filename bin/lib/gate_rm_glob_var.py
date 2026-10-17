"""PreToolUse(Bash) no-wildcard-rm guard; called by bin/hooks/gate-rm-glob-var.sh (stdin = hook payload).
Exit 2 blocks (reason on stderr); exit 0 allows. A seatbelt against accidental cleanup, not a sandbox (gaps: docs/ENFORCEMENT.md)."""
import json, re, shlex, sys

RULING = ("BLOCKED (no-wildcard-rm ruling, operator 2026-10-17): {what}. A wildcard or variable in a removal path "
          "matches whatever is there at run time: on 2026-10-17 a sub-agent's `rm -rf /tmp/tmp.*` deleted two live "
          "pre-push gate files and a push went out unverified. Instead: move it aside (mv <exact path> "
          "<exact path>.moved-aside-$(date +%F)), or leave it and report the leftover. Name exact literal paths.")
WRAP = {"command", "sudo", "doas", "nohup", "time", "exec", "nice", "stdbuf", "builtin", "env", "timeout",
        "ionice", "setsid", "flock", "chrt", "taskset", "unbuffer"}
KEYWORDS = {"do", "then", "else", "elif", "if", "{", "!", "while", "until", "done", "fi"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
REMOVERS = {"rm", "unlink"}
DYNAMIC = re.compile(r"[*?\[$`]")
INTERP = {"python", "python3", "perl", "ruby", "node"}
INTERP_DEL = re.compile(r"rmtree|os\.remove|os\.unlink|\bunlink\b|rm_rf|fs\.rm|rmSync|unlinkSync|\.unlink\(|remove_dir_all|FileUtils\.rm|File\.delete")
INTERP_DYN = re.compile(r"glob|[*?$]|readdir|listdir|scandir|iterdir|\bwalk|forEach|\bfor\b")
interp_bodies = []   # code fed to an interpreter by heredoc, here-string or pipe
RAW_RM = re.compile(r"(^|[\s;&|(`'\"/\\])(rm|unlink)(\s|$)|-delete\b")
HEREDOC = re.compile(r"(?<!<)<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")

try:
    d = json.loads(sys.stdin.read() or "{}")
    cmd = (d.get("tool_input") or {}).get("command") or ""
    if d.get("tool_name") != "Bash" or not isinstance(cmd, str):
        sys.exit(0)
except Exception:
    sys.exit(0)
hits = []

def strip_comments(text):
    """Drop shell comments the way bash does: `#` starts one only at the start of a word and
    outside quotes. shlex would cut at ANY unquoted `#`, so `rm -rf /tmp/a#*` lost its glob and
    read as a literal path, while bash removes everything the glob matches."""
    out, i, n = [], 0, len(text)
    q = None   # the open quote, or None
    while i < n:
        c = text[i]
        if q:
            out.append(c)
            if c == "\\" and q == '"' and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == q: q = None
            i += 1; continue
        if c == "\\" and i + 1 < n:
            out.append(c); out.append(text[i + 1]); i += 2; continue
        if c in "'\"":
            q = c; out.append(c); i += 1; continue
        if c == "#" and (not out or out[-1] in " \t\n;&|("):
            while i < n and text[i] != "\n": i += 1
            continue
        out.append(c); i += 1
    return "".join(out)


def segments(text):
    lex = shlex.shlex(strip_comments(text), posix=True, punctuation_chars=";&|()\n")
    lex.whitespace = " \t\r"; lex.whitespace_split = True
    lex.commenters = ""   # comments are already gone; a bare `#` in a path is data
    segs, cur = [], []
    for t in lex:
        if t and set(t) <= set(";&|()\n"):
            if cur: segs.append(cur); cur = []
        else:
            cur.append(t)
    if cur: segs.append(cur)
    return segs

def heredocs(text):
    # A heredoc body is data (a file being written) unless a shell reads it.
    out, pending = [], []
    for line in text.split("\n"):
        if pending:
            delim, tabs, keep = pending[0]
            if (line.lstrip("\t") if tabs else line) == delim: pending.pop(0)
            elif keep == "interp": interp_bodies[-1].append(line)
            elif keep: out.append(line)
            continue
        out.append(line)
        for m in HEREDOC.finditer(line):
            words = [w for w in re.split(r"[\s;&|(]+", line[:m.start()]) if w and not w.startswith("-")]
            reader = words[-1].rsplit("/", 1)[-1] if words else ""
            keep = reader in SHELLS
            if reader in INTERP or re.match(r"^python3?\.[0-9]+$", reader):
                interp_bodies.append([]); keep = "interp"
            pending.append((m.group(3), m.group(1) == "-", keep))
    return "\n".join(out)

def paths(args):
    out, opts = [], True
    for a in args:
        if opts and a == "--": opts = False; continue
        if opts and a.startswith("-") and len(a) > 1: continue
        out.append(a)
    return out

def scan(text, depth=0):
    if depth > 4: return
    text = heredocs(text)
    for m in re.finditer(r"`([^`]*)`|\$\(([^()]*)\)", text):
        scan(m.group(1) or m.group(2) or "", depth + 1)
    try:
        segs = segments(text)
    except ValueError:
        # Unparseable (e.g. $'...' ANSI-C quoting) but bash may still run it: refuse any removal in it.
        if RAW_RM.search(text): hits.append("a command this guard cannot parse that contains rm, unlink or -delete")
        return
    def unwrap(sg):
        # Leading keywords, VAR=value assignments and wrappers (`sudo bash`, `timeout 5 bash`)
        # are not the command: strip them before asking what the command IS.
        s2 = list(sg)
        while s2 and s2[0] in KEYWORDS: s2 = s2[1:]
        while s2 and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", s2[0]): s2 = s2[1:]
        while s2 and s2[0].rsplit("/", 1)[-1] in WRAP:
            j = next((k for k, t in enumerate(s2[1:], 1) if not t.startswith("-") and "=" not in t
                      and not re.match(r"^[0-9.]+[smhd]?$", t)), None)
            s2 = s2[j:] if j else []
        return s2

    def reader_of(sg, names):
        # The segment is a bare reader (`| bash`, `| sudo bash`, `| python3`) when, after the
        # wrappers, its command is one of `names` and it is given no non-option argument.
        s2 = unwrap(sg)
        if not s2: return ""
        b = s2[0].rsplit("/", 1)[-1]
        ok = b in names or (names is INTERP and re.match(r"^python3?\.[0-9]+$", b))
        return b if ok and not any(not t.startswith("-") for t in s2[1:]) else ""

    if any(reader_of(sg, SHELLS) for sg in segs[1:]):
        # `... | bash`: the shell runs whatever earlier segments print; removal text fed to it is refused.
        fed = " ".join(t for sg in segs if not reader_of(sg, SHELLS) for t in sg)
        if RAW_RM.search(fed): hits.append("removal text piped into a shell")
    for i, sg in enumerate(segs):
        if i and reader_of(sg, INTERP):
            # `... | python3`: the interpreter runs what earlier segments print.
            interp_bodies.append([" ".join(t for x in segs[:i] for t in x)])
    for s in segs:
        while s and s[0] in KEYWORDS: s = s[1:]
        while s and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", s[0]): s = s[1:]
        if s and s[0].rsplit("/", 1)[-1] == "xargs":
            j = next((k for k, t in enumerate(s[1:], 1) if t.rsplit("/", 1)[-1] in REMOVERS), None)
            if j: hits.append(f"`xargs {s[j]}` removes paths read at run time")
            continue
        while s and s[0].rsplit("/", 1)[-1] in WRAP:
            j = next((k for k, t in enumerate(s[1:], 1) if not t.startswith("-") and "=" not in t
                      and not re.match(r"^[0-9.]+[smhd]?$", t)), None)
            s = s[j:] if j else []
        if not s: continue
        base = s[0].rsplit("/", 1)[-1]
        if base in SHELLS:
            for k, t in enumerate(s[1:-1], 1):
                if t == "<<<" and RAW_RM.search(s[k + 1]): hits.append("removal text here-stringed into a shell")
                if t == "-c" or (t.startswith("-") and not t.startswith("--") and "c" in t):
                    scan(s[k + 1], depth + 1); break
            continue
        if base in INTERP or re.match(r"^python3?\.[0-9]+$", base):
            for k, t in enumerate(s[1:-1], 1):
                if t == "<<<": interp_bodies.append([s[k + 1]])
                if t in ("-c", "-e", "-E") or (base == "perl" and t.startswith("-") and "e" in t):
                    if INTERP_DEL.search(s[k + 1]) and INTERP_DYN.search(s[k + 1]):
                        hits.append(f"`{base}` inline code deleting a globbed or variable path")
                    break
            continue
        if base == "eval":
            scan(" ".join(s[1:]), depth + 1); continue
        if base in REMOVERS:
            bad = [p for p in paths(s[1:]) if DYNAMIC.search(p)]
            if bad: hits.append(f"`{base}` with {bad[0]!r} in the path")
        elif base == "find":
            deletes = "-delete" in s or any(t in ("-exec", "-execdir", "-ok", "-okdir") and k + 1 < len(s)
                                             and s[k + 1].rsplit("/", 1)[-1] in REMOVERS for k, t in enumerate(s))
            bad = [t for t in s[1:] if DYNAMIC.search(t) and t not in ("{}", "{}+")]
            if deletes and bad: hits.append(f"`find ... -delete` with {bad[0]!r} in a path or name")

try:
    scan(cmd)
    for body in interp_bodies:
        text = "\n".join(body)
        if INTERP_DEL.search(text) and INTERP_DYN.search(text):
            hits.append("interpreter code (heredoc, here-string or pipe) deleting a globbed or listed path")
except Exception:
    sys.exit(0)
if hits:
    print(RULING.format(what=hits[0]), file=sys.stderr)
    sys.exit(2)
sys.exit(0)
