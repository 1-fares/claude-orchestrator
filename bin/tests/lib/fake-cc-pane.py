#!/usr/bin/env python3
"""A fake Claude Code input box for tests of bin/lib/tmux-input.sh: runs in a scratch tmux pane, never a model.

Drawn as real claude 2.1.312 draws it (bin/tests/fixtures/tmux-input/*.raw, captured 2026-11-02): the box row is `❯` +
U+00A0 at column 0 under a `─` separator, an empty box shows a dim (ESC[2m) placeholder, the footer under the box says
"-- INSERT --" only in INSERT. --menu draws a menu above the box (as after /clear); --picker replaces the box with a
picker (as /model, the trust prompt) until Escape.
Keys, measured: `i` in INSERT is a literal, C-u clears, Escape goes to NORMAL, dd/cc/S clear, Enter submits from INSERT
and from NORMAL, a long text shows as [Pasted text #1] and one Enter submits it. In NORMAL, text is read as vim
commands: t/f/r take the next key, y/d/c are operators, a/A/i/I/s/S enter INSERT, anything else is dropped; that turns
"try again" into "gain" and "/usage" into "age", as in real transcripts. Keys sent together are NOT lost (the old
blind recipe measured 4/4 on a real pane). Submissions are appended to --log, one per line.
"""
import argparse, os, re, select, sys, termios, tty

p = argparse.ArgumentParser()
p.add_argument("--mode", choices=["insert", "normal", "nonvim"], default="insert")
p.add_argument("--log", required=True)
p.add_argument("--box", default="")
p.add_argument("--menu", action="store_true")
p.add_argument("--picker", action="store_true")
p.add_argument("--placeholder", default='Try "write a test for <filepath>"')
p.add_argument("--never-submit", action="store_true")
p.add_argument("--no-prompt", action="store_true")
a = p.parse_args()

LONG = 200
NBSP = " "
mode, box, pasted, pending, picker = a.mode, a.box, "", "", a.picker


def render():
    shown = box + ("[Pasted text #1]" if pasted else "")
    if not shown:
        shown = "\x1b[2m" + a.placeholder + "\x1b[0m"
    status = "  -- INSERT -- ⏵⏵ bypass permissions on" if mode == "insert" else "  ⏵⏵ bypass permissions on"
    out = "\x1b[2J\x1b[H" + "fake pane\n"
    if picker:
        out += "─" * 40 + "\n   Select model\n     1. Default\n   ❯" + NBSP + "2. Opus\n"
        out += "   Enter to set as default · Esc to cancel\n"
    else:
        if a.menu:
            out += "─" * 40 + "\n  Teach auto mode?\n  ❯" + NBSP + "1. Yes\n    2. Not now\n  Enter to confirm · Esc to cancel\n"
        out += "─" * 40 + "\n"
        if not a.no_prompt:
            out += "\x1b[39m❯" + NBSP + shown + "\n"
        out += "─" * 40 + "\n" + status + "\n"
    sys.stdout.write(out.replace("\n", "\r\n"))  # raw mode: no newline translation
    sys.stdout.flush()


def submit():
    global box, pasted
    text = box + pasted
    if not text or a.never_submit:
        return
    with open(a.log, "a") as f:
        f.write(text + "\n")
    box, pasted = "", ""


def insert_text(s):
    global box, pasted
    if len(s) > LONG:
        pasted += s
    else:
        box += s


def key(c):
    global mode, box, pasted, pending, picker
    if picker:
        if c == "\x1b":
            picker = False
        elif c == "\r":
            with open(a.log, "a") as f:
                f.write("<picker answered>\n")
        return
    if c == "\r":
        submit()
        return
    if mode == "normal":
        if pending:
            if pending + c in ("dd", "cc"):
                box, pasted = "", ""
                if c == "c":
                    mode = "insert"
            pending = ""
        elif c in "dcytfr":
            pending = c
        elif c == "S":
            box, pasted, mode = "", "", "insert"
        elif c in "aAiIs":
            mode = "insert"
        return
    if c == "\x15":
        box, pasted = "", ""
    elif c == "\x7f":
        if pasted:
            pasted = ""
        else:
            box = box[:-1]
    elif c == "\x1b":
        if mode == "insert":
            mode = "normal"
    elif c.isprintable():
        insert_text(c)


fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    render()
    while True:
        select.select([fd], [], [])
        s = re.sub(r"\x1b\[[0-9;]*[A-Za-z~]", "", os.read(fd, 65536).decode("utf-8", "replace"))  # arrows move nothing
        run = ""
        for c in s:
            # A printable run read at once is one paste (a long one collapses); every control key still acts, in order.
            if c.isprintable() and mode != "normal" and not picker:
                run += c
                continue
            if run:
                insert_text(run)
                run = ""
            key(c)
        if run:
            insert_text(run)
        render()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
