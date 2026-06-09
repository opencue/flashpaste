#!/usr/bin/env python3
"""Read `kitten @ ls --match state:focused` JSON on stdin; exit 0 iff the
focused kitty window's foreground process is tmux.

Used by kitty-paste-router.sh to suppress kitty's redundant ctrl+v handler
when tmux's own `bind -n C-v` will handle the paste. Exit non-zero on ANY
uncertainty (no data, parse error, no tmux) so the caller falls through to
the normal paste path — a miss must degrade to "paste anyway", never to a
silent no-op.

Why the foreground process: when tmux runs inside a kitty window, that
window's child IS the tmux client; the inner shells live under the tmux
server's process tree, not the kitty window. So a focused window whose
foreground process is `tmux` reliably means "this Ctrl+V is inside tmux".
"""
import json
import sys


def _is_tmux_cmdline(cmdline):
    if not cmdline:
        return False
    exe = cmdline[0].rsplit("/", 1)[-1]
    return exe == "tmux" or exe.startswith("tmux")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 1
    if not isinstance(data, list):
        return 1
    for os_window in data:
        for tab in os_window.get("tabs", []):
            for window in tab.get("windows", []):
                # Only consider a window we can POSITIVELY confirm is focused.
                # `--match state:focused` already filters to it (and sets
                # is_focused=true), so requiring True here is exact on modern
                # kitty. On older kitty that ignores the match and returns
                # every window WITHOUT is_focused, no window qualifies -> we
                # report "not tmux" -> the router falls through and the paste
                # still happens. That is the fail-safe direction: never
                # suppress a paste on a window we cannot prove is focused.
                if window.get("is_focused") is not True:
                    continue
                for proc in window.get("foreground_processes", []):
                    if _is_tmux_cmdline(proc.get("cmdline")):
                        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
