"""
poll.py — replaces Monitor() push delivery for GitHub Copilot CLI port.

In Claude Code, Monitor(command="client.py") runs a background process and
delivers each stdout line to the model in real-time. Copilot CLI has no
Monitor() tool, so this script is called explicitly to check for pending
messages.

Usage:
    python3 poll.py --name <session-name> [--team-dir <path>] [--clear]

Output:
    Prints any pending messages to stdout, one per line in the format:
    [inter-session msg=<id> from="<sender>"] <text>

    Exits 0 if messages found, 1 if no pending messages.

Options:
    --name <name>        Your session name on the bus
    --team-dir <path>    Team state directory (default: $TEAM_DIR)
    --clear              Delete messages after reading (default: true)
    --no-clear           Leave messages in inbox after reading

TODO(copilot-port): implement this script
"""

import argparse
import os
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Poll for inter-session messages")
    parser.add_argument("--name", required=True, help="Your session name")
    parser.add_argument("--team-dir", default=os.getenv("TEAM_DIR"), help="Team state dir")
    parser.add_argument("--clear", action="store_true", default=True)
    parser.add_argument("--no-clear", dest="clear", action="store_false")
    args = parser.parse_args()

    team_dir = args.team_dir
    if not team_dir:
        print("ERROR: --team-dir or $TEAM_DIR required", file=sys.stderr)
        sys.exit(2)

    inbox = Path(team_dir) / "msgs" / args.name

    # TODO(copilot-port): implement message reading from inbox directory
    # 1. Check if inbox exists; if not, exit 1 (not connected)
    # 2. List all .msg files sorted by filename (timestamp order)
    # 3. For each file, read and print in [inter-session ...] format
    # 4. If --clear, delete each file after reading
    # 5. Exit 0 if any messages found, 1 if empty

    raise NotImplementedError("TODO(copilot-port): implement poll.py")


if __name__ == "__main__":
    main()
