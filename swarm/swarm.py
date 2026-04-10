#!/usr/bin/env python3
"""
swarm.py — Unified CLI for tmux-based multi-agent Claude Code coordination.

Usage:
  swarm spawn <worker-name> <task>    Create worker window, start dangerclaude, send task
  swarm send  <worker-name> <msg>     Send message to existing worker window
  swarm kill  <worker-name>           Kill worker window
  swarm status                        List session windows and pending issues
  swarm ping  [message]               Send message to orchestrator
  swarm report-issue <desc>           Log issue for self-improving agent
  swarm session-start                 (hook) Detect identity, emit role prompt
  swarm stop-hook                     (hook) Worker→orchestrator or NOTIFY HUMAN
"""

from __future__ import annotations

# ── Auto-install libtmux ──────────────────────────────────────────────────────
try:
    import libtmux
except ImportError:
    import sys as _sys, json as _json, os as _os, tempfile as _tempfile
    import urllib.request as _urlreq, zipfile as _zipfile
    from pathlib import Path as _Path

    def _vendor_libtmux() -> None:
        vendor_dir = _Path(__file__).parent / "vendor"
        vendor_dir.mkdir(exist_ok=True)
        vendor_str = str(vendor_dir)
        if vendor_str not in _sys.path:
            _sys.path.insert(0, vendor_str)

        if (vendor_dir / "libtmux").exists():
            return  # already vendored

        print("[swarm] Vendoring libtmux from PyPI...", file=_sys.stderr)
        with _urlreq.urlopen("https://pypi.org/pypi/libtmux/json") as r:
            data = _json.loads(r.read())

        latest = data["info"]["version"]
        wheels = [
            f for f in data["releases"][latest]
            if f["filename"].endswith("-py3-none-any.whl")
        ]
        if not wheels:
            raise RuntimeError("[swarm] No pure-Python wheel found for libtmux")

        url = wheels[0]["url"]
        print(f"[swarm] Downloading {wheels[0]['filename']}...", file=_sys.stderr)
        with _tempfile.NamedTemporaryFile(suffix=".whl", delete=False) as tmp:
            with _urlreq.urlopen(url) as r:
                tmp.write(r.read())
            tmp_path = tmp.name

        try:
            with _zipfile.ZipFile(tmp_path) as zf:
                members = [m for m in zf.namelist() if m.startswith("libtmux/")]
                zf.extractall(vendor_dir, members)
        finally:
            _os.unlink(tmp_path)

        print("[swarm] libtmux vendored OK.", file=_sys.stderr)

    _vendor_libtmux()
    import libtmux  # noqa: E402

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# ── Constants ─────────────────────────────────────────────────────────────────

SCRIPT_DIR    = Path(__file__).parent
RUNTIME_ROOT  = Path(os.environ.get("SWARM_RUNTIME_ROOT", "/tmp/claude-swarm"))
LOG_DIR       = RUNTIME_ROOT / "logs"
RUNTIME_DIR   = RUNTIME_ROOT / "runtime"
ISSUES_DIR    = SCRIPT_DIR / ".issues"
LAST_SEND_TS  = RUNTIME_DIR / "last_orchestrator_send"
LAUNCH_CMD    = "dangerclaude"
NOTIFY_SCRIPT = Path.home() / ".claude" / "hooks" / "notify-openclaw.sh"
NOTIFY_HUMAN_SIGNAL = "NOTIFY HUMAN"

# Minimum gap (seconds) between successive sends to orchestrator.
# Prevents character interleaving when multiple workers finish simultaneously.
ORCHESTRATOR_SEND_GAP = 0.6

# ── libtmux helpers ───────────────────────────────────────────────────────────

def get_server() -> libtmux.Server:
    return libtmux.Server()


def get_current_pane(server: libtmux.Server) -> libtmux.Pane:
    """
    Return the pane that owns this process, anchored to TMUX_PANE env var.

    TMUX_PANE is set by tmux when a shell starts inside a pane, and is
    inherited by all child processes (including Claude Code hooks).
    We iterate to find the matching pane object rather than relying on
    server.find_where(), which could silently match the wrong session.
    """
    pane_id = os.environ.get("TMUX_PANE")
    if not pane_id:
        raise RuntimeError("TMUX_PANE not set — not running inside tmux")
    for session in server.sessions:
        for window in session.windows:
            for pane in window.panes:
                if pane.id == pane_id:
                    return pane
    raise RuntimeError(f"Pane {pane_id!r} not found in any session")


def find_orchestrator_window(session: libtmux.Session) -> libtmux.Window | None:
    """
    Find the orchestrator window within a SPECIFIC session.

    Matches window names starting with 'orchestrator' (allowing tmux's
    auto-rename suffix like 'orchestrator-').  Always scoped to the
    provided session — never searches across sessions.
    """
    import re
    for window in session.windows:
        if re.match(r"^orchestrator(-|$)", window.name):
            return window
    return None


def find_window(session: libtmux.Session, name: str) -> libtmux.Window | None:
    """
    Find a window by exact name within a SPECIFIC session.

    NOTE: always pass the session object obtained from the current pane,
    never look up a session by name string — that risks cross-session confusion.
    """
    for window in session.windows:
        if window.name == name:
            return window
    return None


def find_self_improving_pane(server: libtmux.Server) -> libtmux.Pane | None:
    """
    Search ALL sessions for a window named 'claude-self-improving'.

    This is intentionally cross-session: the self-improving agent may run
    in any session on the machine.  We do NOT use this for swarm operations.
    """
    for session in server.sessions:
        for window in session.windows:
            if window.name == "claude-self-improving":
                return window.panes[0]
    return None


# ── Issue reporting ───────────────────────────────────────────────────────────

def report_issue(description: str, component: str = "unknown") -> None:
    """
    Persist an issue to .issues/ and optionally notify the self-improving agent.

    Always writes to disk first (persistent record), then tries to ping
    the agent if it is running.  The disk write is the source of truth;
    the tmux ping is best-effort.
    """
    try:
        ISSUES_DIR.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        issue_file = ISSUES_DIR / f"{ts}-{component}.md"
        issue_file.write_text(
            f"---\ndate: {datetime.now().isoformat()}\n"
            f"component: {component}\nstatus: pending_review\n---\n\n"
            f"## 问题描述\n\n{description}\n"
        )
    except Exception:
        pass  # never raise from error reporter

    # Try to notify self-improving agent (best-effort, cross-session search)
    try:
        server = get_server()
        pane = find_self_improving_pane(server)
        if pane:
            short_desc = description[:200].replace("\n", " ")
            pane.send_keys(
                f"[swarm-auto-report][{component}] {short_desc}",
                enter=True,
            )
    except Exception:
        pass


# ── Orchestrator send with concurrency protection ─────────────────────────────

def _wait_for_copy_mode_exit(pane: libtmux.Pane, timeout: float = 30) -> bool:
    """
    Wait until pane exits copy mode (or other mode).

    Returns True if exited normally, False if timeout.
    """
    start = time.time()
    check_interval = 0.1

    while time.time() - start < timeout:
        try:
            # Query tmux for pane_in_mode variable
            result = pane.cmd(
                "display-message", "-p", "-t", pane.id, "#{pane_in_mode}"
            )
            in_mode = result.stdout[0].strip() if result.stdout else "0"
            if in_mode == "0":
                return True
        except Exception:
            # If we can't query, assume not in mode and proceed
            return True
        time.sleep(check_interval)

    return False  # Timeout


def send_to_orchestrator_safe(
    session: libtmux.Session, sender: str, message: str
) -> None:
    """
    Send a message to the orchestrator window with soft serialization.

    Multiple workers finishing at the same time would each call this
    function in their respective stop-hook processes.  We use a shared
    timestamp file to ensure at least ORCHESTRATOR_SEND_GAP seconds
    between successive sends, preventing character-level interleaving
    in the orchestrator's terminal input buffer.

    session: the CURRENT worker's session — orchestrator is found within it.
    """
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)

    # Soft lock: wait until enough time has passed since the last send
    if LAST_SEND_TS.exists():
        try:
            last = float(LAST_SEND_TS.read_text().strip())
            elapsed = time.time() - last
            if elapsed < ORCHESTRATOR_SEND_GAP:
                time.sleep(ORCHESTRATOR_SEND_GAP - elapsed + 0.05)
        except (ValueError, OSError):
            pass

    LAST_SEND_TS.write_text(str(time.time()))

    orch_window = find_orchestrator_window(session)
    if not orch_window:
        report_issue(
            f"Worker '{sender}' tried to report but no orchestrator window "
            f"found in session '{session.name}'",
            component="stop-hook",
        )
        return

    pane = orch_window.panes[0]

    # Wait if orchestrator pane is in copy mode (e.g., user scrolling)
    # to avoid sending keys into the copy mode buffer
    _wait_for_copy_mode_exit(pane, timeout=30)

    pane.send_keys(f"[{sender}] {message}", enter=True)
    time.sleep(0.3)
    pane.send_keys("", enter=True)  # flush bracketed-paste buffer


# ── Logging ───────────────────────────────────────────────────────────────────

def _log(message: str) -> None:
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_DIR / "swarm.log", "a") as f:
            f.write(f"[{ts}] {message}\n")
    except Exception:
        pass


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_spawn(args: argparse.Namespace) -> None:
    """
    Create a new worker window and send its initial task.

    Key design decisions:
    - new_window(attach=False): does NOT steal focus from orchestrator window,
      eliminating the window-switch confusion bug from the old bash scripts.
    - set_window_option("automatic-rename", "off"): locks the window name so
      tmux's auto-rename never corrupts 'worker-alice' → 'bash', which would
      cause subsequent find_window() calls to fail.
    - All send_keys calls use the pane object directly — no string target
      that tmux could misparse.
    """
    server = get_server()
    current_pane = get_current_pane(server)
    # Session is always derived from current pane — never looked up by name
    session = current_pane.window.session
    worker_name: str = args.name
    task: str = args.task

    if find_window(session, worker_name):
        print(
            f"Error: worker window '{worker_name}' already exists "
            f"in session '{session.name}'",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        # Create window without switching focus
        window = session.new_window(window_name=worker_name, attach=False)
        # Prevent tmux auto-rename from overwriting the worker name
        window.set_window_option("automatic-rename", "off")
        pane = window.panes[0]

        time.sleep(1)
        pane.send_keys(LAUNCH_CMD, enter=True)
        # Wait for Claude to start and session-start hook to complete
        time.sleep(3)
        pane.send_keys(task, enter=True)
        time.sleep(0.3)
        pane.send_keys("", enter=True)  # flush bracketed-paste buffer

        print(f"Spawned worker '{worker_name}' in session '{session.name}'")
        _log(f"[{session.name}] spawned {worker_name}")

    except Exception as e:
        report_issue(
            f"spawn failed for worker '{worker_name}': {e}",
            component="spawn",
        )
        raise


def cmd_send(args: argparse.Namespace) -> None:
    """Send a message/task to an existing worker window."""
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session
    worker_name: str = args.name
    message: str = args.message

    window = find_window(session, worker_name)
    if not window:
        print(
            f"Error: worker window '{worker_name}' not found "
            f"in session '{session.name}'",
            file=sys.stderr,
        )
        sys.exit(1)

    pane = window.panes[0]

    # Wait if worker pane is in copy mode (user scrolling history)
    _wait_for_copy_mode_exit(pane, timeout=10)

    pane.send_keys(message, enter=True)
    time.sleep(0.3)
    pane.send_keys("", enter=True)
    print(f"Sent to '{worker_name}'")
    _log(f"[{session.name}] send → {worker_name}")


def cmd_kill(args: argparse.Namespace) -> None:
    """Kill a worker window."""
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session
    worker_name: str = args.name

    window = find_window(session, worker_name)
    if not window:
        print(
            f"Error: window '{worker_name}' not found "
            f"in session '{session.name}'",
            file=sys.stderr,
        )
        sys.exit(1)

    window.kill()
    print(f"Killed worker '{worker_name}'")
    _log(f"[{session.name}] killed {worker_name}")


def cmd_status(args: argparse.Namespace) -> None:
    """List all windows in current session and pending issues."""
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session

    print(f"Session: {session.name}")
    print(f"\n{'Window':<28} {'Active'}")
    print("─" * 36)
    for window in session.windows:
        active = "◀" if any(p.id == current_pane.id for p in window.panes) else ""
        print(f"{window.name:<28} {active}")

    if ISSUES_DIR.exists():
        pending = sorted(ISSUES_DIR.glob("*.md"))
        if pending:
            print(f"\n⚠  {len(pending)} unreviewed issue(s) in {ISSUES_DIR}")
            for f in pending[-3:]:  # show last 3
                print(f"   {f.name}")
            if len(pending) > 3:
                print(f"   ... and {len(pending) - 3} more")


def cmd_ping(args: argparse.Namespace) -> None:
    """Send a message to the orchestrator window."""
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session

    default_msg = (
        "请检查当前 worker 状态、阻塞项，"
        "以及是否需要继续迭代或向 human 汇报。"
    )
    message: str = args.message or default_msg

    orch_window = find_orchestrator_window(session)
    if not orch_window:
        print(
            f"Error: no orchestrator window found in session '{session.name}'",
            file=sys.stderr,
        )
        sys.exit(1)

    pane = orch_window.panes[0]
    pane.send_keys(message, enter=True)
    time.sleep(0.3)
    pane.send_keys("", enter=True)
    print(f"Pinged orchestrator in session '{session.name}'")


def cmd_report_issue(args: argparse.Namespace) -> None:
    """Manually log an issue for the self-improving agent."""
    report_issue(args.description, component=args.component)
    print(f"Issue logged to {ISSUES_DIR}/")


def cmd_session_start() -> None:
    """
    Called by hooks/session-start.sh at Claude Code startup.

    Determines orchestrator/worker identity from the current pane's window
    name and session context, renames the window if this is the first Claude
    in the session (→ orchestrator), and emits the appropriate role prompt
    as a system-reminder injected into Claude's context.
    """
    if not os.environ.get("TMUX"):
        sys.exit(0)

    try:
        server = get_server()
        current_pane = get_current_pane(server)
        current_window = current_pane.window
        session = current_window.session

        session_name = session.name
        window_name = current_window.name

        orch_window = find_orchestrator_window(session)

        if orch_window is None:
            # First Claude in this session — become orchestrator
            current_window.rename_window("orchestrator")
            current_window.set_window_option("automatic-rename", "off")
            identity = "orchestrator"
        elif current_window.id == orch_window.id:
            # Resuming / /clear in the orchestrator window
            identity = "orchestrator"
        else:
            # A worker window: identity = window name (e.g. 'worker-alice')
            identity = window_name

        role_upper = "ORCHESTRATOR" if identity == "orchestrator" else "WORKER"

        print("╔══════════════════════════════════════════════╗")
        print("║       SWARM MODE ACTIVE — ACTION REQUIRED    ║")
        print("╚══════════════════════════════════════════════╝")
        print()
        print(
            f"你的角色：{role_upper}"
            f"（identity: {identity}，session: {session_name}）"
        )
        print()
        print("以下是你必须立即遵守的行为规范（优先于处理任何用户消息）：")
        print("━" * 46)
        print()

        prompt_file = (
            SCRIPT_DIR / "orchestrator.md"
            if identity == "orchestrator"
            else SCRIPT_DIR / "worker.md"
        )
        print(prompt_file.read_text())
        print()
        print("━" * 46)

    except Exception as e:
        report_issue(str(e), component="session-start")
        # Always exit 0 — Claude must start regardless of hook failures
        sys.exit(0)


def cmd_stop_hook() -> None:
    """
    Called by hooks/stop-hook.sh when Claude finishes a turn.
    Reads the Claude Code stop-hook JSON payload from stdin.

    Orchestrator path:
      Checks for NOTIFY HUMAN signal in last_assistant_message.
      If found, calls notify-openclaw.sh to send a human notification.
      Does NOT forward the message to anyone else.

    Worker path:
      Forwards last_assistant_message to the orchestrator window.
      Uses send_to_orchestrator_safe() to prevent character interleaving
      when multiple workers finish at the same time.
    """
    if not os.environ.get("TMUX"):
        sys.exit(0)

    try:
        server = get_server()
        current_pane = get_current_pane(server)
        current_window = current_pane.window
        session = current_window.session
        identity = current_window.name

        # Parse hook payload (shared by both paths)
        raw = sys.stdin.read()
        try:
            data = json.loads(raw)
            last_message: str = data.get("last_assistant_message", "")
        except json.JSONDecodeError as e:
            report_issue(
                f"stop-hook JSON parse failed: {e}\nraw (first 300): {raw[:300]}",
                component="stop-hook",
            )
            sys.exit(0)

        # ── Orchestrator path ──────────────────────────────────────────────
        # self-improving agent is also an orchestrator-like role
        if identity.startswith("orchestrator") or identity == "claude-self-improving":
            if last_message and NOTIFY_HUMAN_SIGNAL in last_message:
                _log(
                    f"[{session.name}:orchestrator] "
                    f"NOTIFY HUMAN detected → notify-openclaw.sh"
                )
                if NOTIFY_SCRIPT.exists():
                    try:
                        # Pass the last message to notify script via env var
                        env = os.environ.copy()
                        env["CLAUDE_LAST_MESSAGE"] = last_message[:2000]  # Limit to avoid env size issues
                        subprocess.run(
                            ["bash", str(NOTIFY_SCRIPT)],
                            timeout=30,
                            check=False,
                            env=env,
                        )
                    except Exception as notify_err:
                        report_issue(
                            f"notify-openclaw.sh failed: {notify_err}",
                            component="notify",
                        )
                else:
                    _log(f"notify-openclaw.sh not found at {NOTIFY_SCRIPT}")
            sys.exit(0)

        # ── Worker path ────────────────────────────────────────────────────
        if not last_message:
            sys.exit(0)

        send_to_orchestrator_safe(session, identity, last_message)
        _log(f"[{session.name}:{identity}] NOTIFY OK")

    except Exception as e:
        report_issue(str(e), component="stop-hook")
        sys.exit(0)  # never block Claude from exiting


# ── CLI wiring ────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Swarm CLI — tmux-based multi-agent coordination for Claude Code",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # spawn
    p = sub.add_parser("spawn", help="Create worker window and send initial task")
    p.add_argument("name", help="Worker window name (e.g. worker-alice)")
    p.add_argument("task", help="Initial task description")
    p.set_defaults(func=cmd_spawn)

    # send
    p = sub.add_parser("send", help="Send message to existing worker window")
    p.add_argument("name", help="Worker window name")
    p.add_argument("message", help="Message / task to send")
    p.set_defaults(func=cmd_send)

    # kill
    p = sub.add_parser("kill", help="Kill a worker window")
    p.add_argument("name", help="Worker window name")
    p.set_defaults(func=cmd_kill)

    # status
    p = sub.add_parser("status", help="List session windows and pending issues")
    p.set_defaults(func=cmd_status)

    # ping
    p = sub.add_parser("ping", help="Send message to orchestrator")
    p.add_argument("message", nargs="?", default=None,
                   help="Custom message (default: standard check-in prompt)")
    p.set_defaults(func=cmd_ping)

    # report-issue
    p = sub.add_parser("report-issue", help="Log issue for self-improving agent")
    p.add_argument("description", help="Issue description")
    p.add_argument("--component", default="unknown",
                   help="Component tag (e.g. spawn, stop-hook, session-start)")
    p.set_defaults(func=cmd_report_issue)

    # Internal hooks (called by bash wrappers in hooks/)
    p = sub.add_parser("session-start", help="(hook) Detect identity, emit role prompt")
    p.set_defaults(func=lambda _args: cmd_session_start())

    p = sub.add_parser("stop-hook", help="(hook) Worker→orchestrator or NOTIFY HUMAN")
    p.set_defaults(func=lambda _args: cmd_stop_hook())

    args = parser.parse_args()
    try:
        args.func(args)
    except SystemExit as e:
        # Log non-zero exits (errors) but not --help (code 0)
        if e.code != 0 and e.code is not None:
            report_issue(
                f"Command '{args.command}' exited with code {e.code}",
                component=args.command,
            )
        raise
    except Exception as e:
        # Log unexpected errors to issues for self-improving agent review
        report_issue(
            f"Command '{args.command}' failed: {type(e).__name__}: {e}",
            component=args.command,
        )
        raise


if __name__ == "__main__":
    main()
