# Swarm Python Refactor Implementation Plan

## Overview

将 swarm 的 7 个 bash 脚本 + 2 个 hooks 替换为一个统一的 `swarm.py` CLI，以 libtmux 为底层，消除窗口名解析 bug、重复投递、静默失败等问题。同时增加 self-improving agent 基础设施，用于记录运行时发现的问题。

## Current State Analysis

**现有问题（来自前期分析）：**
- `swarm-spawn-claude-worker`：用窗口名作为 send-keys 目标，tmux auto-rename 后静默失败
- `tmux new-window` 默认 attach，导致 focus 切换，引发后续窗口名混乱
- `swarm-send` 同时写 inbox + tmux push，调用方再手动 push → 三重投递
- stop-hook 硬编码 `orchestrator.0`，orchestrator 被 auto-rename 后推送失败
- 多 worker 同时向 orchestrator 发送时，tmux input buffer 有字符交错风险
- `swarm-bootstrap-codex` 依赖不存在的 `codex` 命令 — 死代码

**保留不变：**
- tmux 窗口以人类可读名称标识（`orchestrator`, `worker-alice` 等）
- `/tmp/claude-swarm/` 运行时目录结构（但删除 inbox 子目录）
- `hooks/notify-openclaw.sh` 脚本本身不变，但触发方式改变（见下）

## Desired End State

1. orchestrator 调用 `swarm spawn worker-alice "task"` → 可靠创建 worker，窗口名稳定，任务无重复投递
2. worker stop-hook → 可靠推送最后一条消息到 orchestrator，多 worker 并发无字符交错
3. session-start 正确识别 orchestrator/worker 身份，输出对应 prompt
4. orchestrator.md 只含 `swarm` 命令，无内联 bash 示例
5. 任何 swarm 运行时异常 → 写入 `.issues/`，若 self-improving agent 在线则同时 ping
6. orchestrator 在 last message 中输出 `NOTIFY HUMAN` → stop-hook 触发 notify-openclaw.sh 发通知
7. 所有 tmux 操作严格限定在当前 session，不跨 session 匹配窗口名

## What We're NOT Doing

- 不重新引入 inbox 机制（已决策移除）
- 不修改 `self-improving.md`、`notify-openclaw.sh` 脚本本身
- 不引入 libtmux 以外的第三方依赖

---

## 核心设计原则：Session 隔离

**历史 bug**：`tmux list-windows -t "$session"` 中 `$session` 变量取值错误时，会匹配到其他 session 的同名窗口。

**本次设计的强保证**：

```
所有 swarm 操作的起点 = get_current_pane(server)
                          ↓
                    current_pane.window.session   ← 当前 session 对象
                          ↓
              session.windows  /  session.new_window()
                          ↓
              只操作此 session 内的窗口，绝不跨 session
```

**例外**（有意的跨 session 搜索）：
- `find_self_improving_pane(server)`：遍历所有 session 寻找 `claude-self-improving` 窗口 — 这是 intentional，因为 self-improving agent 可能运行在任何 session 中，注释中须明确标注

**在代码中强制执行**：
- `spawn / send / kill / status / ping` 所有操作：参数类型是 `libtmux.Session`，由调用方从 `current_pane.window.session` 传入
- 无任何函数接受 session name 字符串然后做 `server.find_where({"session_name": ...})`，防止拼写错误或变量错误导致跨 session

```python
# CORRECT: session object comes from current pane
session = get_current_pane(server).window.session
window = find_window(session, "worker-alice")   # scoped to this session

# WRONG (never do this):
session = server.find_where({"session_name": session_name})  # name could be wrong
```

---

## Phase 1：删除死代码，安装 libtmux

### 1.1 删除 bin/ 脚本

删除以下文件：
```
~/.claude/swarm/bin/swarm-ack
~/.claude/swarm/bin/swarm-bootstrap-codex
~/.claude/swarm/bin/swarm-ping-orchestrator
~/.claude/swarm/bin/swarm-read
~/.claude/swarm/bin/swarm-send
~/.claude/swarm/bin/swarm-spawn-claude-worker
~/.claude/swarm/bin/swarm-env.sh
```

保留 `bin/` 目录（空），或删除整个目录。

### 1.2 删除 skill.md（冗余）

`skill.md` 的内容与 `orchestrator.md` 重叠，且含有已废弃的 `tmux rename-window -t "$SESSION:$CURRENT_WINDOW"` 用法。删除：
```
~/.claude/swarm/skill.md
```

### 1.3 libtmux 自动安装

`swarm.py` 顶部处理依赖：
```python
try:
    import libtmux
except ImportError:
    import subprocess, sys
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--user", "libtmux"],
        check=True, capture_output=True
    )
    import libtmux
```

### Success Criteria Phase 1:
- [ ] `ls ~/.claude/swarm/bin/` 为空或目录不存在
- [ ] `skill.md` 不存在
- [ ] `python3 -c "import libtmux; print(libtmux.__version__)"` 成功

---

## Phase 2：实现 swarm.py

### 文件路径

```
~/.claude/swarm/swarm.py
```

### 整体结构

```python
#!/usr/bin/env python3
"""Swarm CLI — tmux-based multi-agent coordination for Claude Code."""

# --- Auto-install libtmux ---
try:
    import libtmux
except ImportError:
    ...

import argparse, json, os, sys, time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR    = Path(__file__).parent
RUNTIME_ROOT  = Path(os.environ.get("SWARM_RUNTIME_ROOT", "/tmp/claude-swarm"))
LOG_DIR       = RUNTIME_ROOT / "logs"
RUNTIME_DIR   = RUNTIME_ROOT / "runtime"
ISSUES_DIR    = SCRIPT_DIR / ".issues"
LAST_SEND_TS  = RUNTIME_DIR / "last_orchestrator_send"
LAUNCH_CMD    = "dangerclaude"

def get_server() -> libtmux.Server: ...
def get_current_pane(server) -> libtmux.Pane: ...  # uses TMUX_PANE env
def find_orchestrator_window(session) -> libtmux.Window | None: ...
def find_window(session, name) -> libtmux.Window | None: ...
def find_self_improving_pane(server) -> libtmux.Pane | None: ...

def report_issue(description: str, component: str = "unknown"): ...
def send_to_orchestrator_safe(session, sender: str, message: str): ...

def cmd_spawn(args): ...
def cmd_send(args): ...
def cmd_kill(args): ...
def cmd_status(args): ...
def cmd_ping(args): ...
def cmd_session_start(): ...
def cmd_stop_hook(): ...
def cmd_report_issue(args): ...

def main():
    parser = argparse.ArgumentParser(description="Swarm CLI")
    sub = parser.add_subparsers(dest="command", required=True)
    ...
```

### 2.1 核心 helpers

```python
def get_server() -> libtmux.Server:
    return libtmux.Server()

def get_current_pane(server: libtmux.Server) -> libtmux.Pane:
    """Get pane corresponding to this process, via TMUX_PANE env var."""
    pane_id = os.environ.get("TMUX_PANE")
    if not pane_id:
        raise RuntimeError("TMUX_PANE not set — not running inside tmux")
    for session in server.sessions:
        for window in session.windows:
            for pane in window.panes:
                if pane.id == pane_id:
                    return pane
    raise RuntimeError(f"Pane {pane_id} not found in any session")

def find_orchestrator_window(session: libtmux.Session) -> libtmux.Window | None:
    """Find window whose name starts with 'orchestrator'."""
    import re
    for window in session.windows:
        if re.match(r'^orchestrator(-|$)', window.name):
            return window
    return None

def find_window(session: libtmux.Session, name: str) -> libtmux.Window | None:
    for window in session.windows:
        if window.name == name:
            return window
    return None

def find_self_improving_pane(server: libtmux.Server) -> libtmux.Pane | None:
    for session in server.sessions:
        for window in session.windows:
            if window.name == "claude-self-improving":
                return window.panes[0]
    return None
```

### 2.2 report_issue（self-improving infrastructure）

```python
def report_issue(description: str, component: str = "unknown"):
    """Log an issue to .issues/ and optionally ping self-improving agent."""
    ISSUES_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    issue_file = ISSUES_DIR / f"{ts}-{component}.md"
    issue_file.write_text(f"""---
date: {datetime.now().isoformat()}
component: {component}
status: pending_review
---

## 问题描述

{description}
""")
    # Try to notify self-improving agent if running
    try:
        server = get_server()
        pane = find_self_improving_pane(server)
        if pane:
            pane.send_keys(
                f"[swarm-auto-report][{component}] {description[:200]}",
                enter=True
            )
    except Exception:
        pass  # notification is best-effort
```

**触发时机**：
- `swarm.py` 内部任何 `except Exception as e` → `report_issue(str(e), component)`
- stop-hook 解析 JSON 失败
- spawn 创建窗口失败
- session-start 无法确定身份时

### 2.3 send_to_orchestrator_safe（并发保护）

```python
def send_to_orchestrator_safe(session: libtmux.Session, sender: str, message: str):
    """
    Send message to orchestrator with soft serialization.
    Multiple workers finishing simultaneously could interleave characters;
    this ensures at least 0.6s gap between successive sends.
    """
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    
    # Soft lock: check when last message was sent
    if LAST_SEND_TS.exists():
        try:
            last = float(LAST_SEND_TS.read_text().strip())
            elapsed = time.time() - last
            if elapsed < 0.6:
                time.sleep(0.6 - elapsed)
        except ValueError:
            pass
    
    LAST_SEND_TS.write_text(str(time.time()))
    
    orch_window = find_orchestrator_window(session)
    if not orch_window:
        report_issue(
            f"Worker '{sender}' tried to report but no orchestrator window found",
            component="stop-hook"
        )
        return
    
    pane = orch_window.panes[0]
    pane.send_keys(f"[{sender}] {message}", enter=True)
    time.sleep(0.3)
    pane.send_keys("", enter=True)  # prevent bracketed paste
```

### 2.4 cmd_spawn

```python
def cmd_spawn(args):
    """
    Create a new worker window, start dangerclaude, send initial task.
    Uses attach=False to avoid stealing tmux focus from orchestrator.
    Sets automatic-rename=off to keep the window name stable.
    """
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session
    worker_name = args.name
    task = args.task

    # Guard: don't create duplicate windows
    if find_window(session, worker_name):
        print(f"Worker '{worker_name}' already exists in session '{session.name}'",
              file=sys.stderr)
        sys.exit(1)

    try:
        # Create window WITHOUT switching focus (attach=False)
        window = session.new_window(
            window_name=worker_name,
            attach=False
        )
        # Lock the name so tmux auto-rename doesn't corrupt it
        window.set_window_option("automatic-rename", "off")
        pane = window.panes[0]

        time.sleep(1)
        pane.send_keys(LAUNCH_CMD, enter=True)
        time.sleep(3)  # wait for Claude to start + session-start hook to fire
        pane.send_keys(task, enter=True)
        time.sleep(0.3)
        pane.send_keys("", enter=True)  # flush bracketed paste buffer

        print(f"Spawned worker '{worker_name}' in session '{session.name}'")

    except Exception as e:
        report_issue(
            f"spawn failed for worker '{worker_name}': {e}",
            component="spawn"
        )
        raise
```

### 2.5 cmd_send

```python
def cmd_send(args):
    """Send a message/task to an existing worker window."""
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session
    worker_name = args.name
    message = args.message

    window = find_window(session, worker_name)
    if not window:
        print(f"Worker window '{worker_name}' not found", file=sys.stderr)
        sys.exit(1)

    pane = window.panes[0]
    pane.send_keys(message, enter=True)
    time.sleep(0.3)
    pane.send_keys("", enter=True)
    print(f"Sent to '{worker_name}'")
```

### 2.6 cmd_kill

```python
def cmd_kill(args):
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session
    window = find_window(session, args.name)
    if not window:
        print(f"Window '{args.name}' not found", file=sys.stderr)
        sys.exit(1)
    window.kill_window()
    print(f"Killed worker '{args.name}'")
```

### 2.7 cmd_status

```python
def cmd_status(args):
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session
    
    print(f"Session: {session.name}")
    print(f"{'Window':<25} {'Active':>6}")
    print("-" * 35)
    for window in session.windows:
        active = "*" if window == current_pane.window else ""
        print(f"{window.name:<25} {active:>6}")
    
    # Show pending issues
    if ISSUES_DIR.exists():
        pending = list(ISSUES_DIR.glob("*.md"))
        if pending:
            print(f"\n⚠  {len(pending)} unreviewed issue(s) in {ISSUES_DIR}")
```

### 2.8 cmd_ping

```python
def cmd_ping(args):
    server = get_server()
    current_pane = get_current_pane(server)
    session = current_pane.window.session
    message = args.message or "请检查当前 worker 状态、阻塞项，以及是否需要继续迭代或向 human 汇报。"
    
    orch_window = find_orchestrator_window(session)
    if not orch_window:
        print("No orchestrator window found", file=sys.stderr)
        sys.exit(1)
    
    pane = orch_window.panes[0]
    pane.send_keys(message, enter=True)
    time.sleep(0.3)
    pane.send_keys("", enter=True)
    print(f"Pinged orchestrator in session '{session.name}'")
```

### 2.9 cmd_session_start

```python
def cmd_session_start():
    """
    Called by hooks/session-start.sh.
    Determines orchestrator/worker identity, renames window if needed,
    locks the name, and emits the appropriate role prompt.
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
            # First Claude in this session → become orchestrator
            current_window.rename_window("orchestrator")
            current_window.set_window_option("automatic-rename", "off")
            identity = "orchestrator"
        elif current_window.id == orch_window.id:
            identity = "orchestrator"
        else:
            identity = window_name  # e.g. "worker-alice"

        role_upper = "ORCHESTRATOR" if identity == "orchestrator" else "WORKER"

        print("╔══════════════════════════════════════════════╗")
        print("║       SWARM MODE ACTIVE — ACTION REQUIRED    ║")
        print("╚══════════════════════════════════════════════╝")
        print()
        print(f"你的角色：{role_upper}（identity: {identity}，session: {session_name}）")
        print()
        print("以下是你必须立即遵守的行为规范（优先于处理任何用户消息）：")
        print("━" * 46)
        print()

        prompt_file = SCRIPT_DIR / (
            "orchestrator.md" if identity == "orchestrator" else "worker.md"
        )
        print(prompt_file.read_text())
        print()
        print("━" * 46)

    except Exception as e:
        report_issue(str(e), component="session-start")
        # Still exit 0 so Claude always starts
        sys.exit(0)
```

### 2.10 cmd_stop_hook

stop-hook 现在需要处理两种身份：

- **orchestrator**：不向其他人汇报，但检测 `NOTIFY HUMAN` 信号 → 调用 `notify-openclaw.sh`
- **worker**：向 orchestrator 推送最后一条消息

`notify-openclaw.sh` 须从 `settings.json` 的 Stop hooks 数组中移除（否则每次 stop 都发通知），
改为由 stop-hook.py 在检测到 `NOTIFY HUMAN` 时主动调用。

```python
NOTIFY_HUMAN_SIGNAL = "NOTIFY HUMAN"
NOTIFY_SCRIPT = Path.home() / ".claude" / "hooks" / "notify-openclaw.sh"

def cmd_stop_hook():
    """
    Called by hooks/stop-hook.sh (reads JSON from stdin).

    Orchestrator path:
      - Detects NOTIFY HUMAN in last message → calls notify-openclaw.sh
      - Does NOT forward to anyone else

    Worker path:
      - Forwards last_assistant_message to orchestrator
      - Concurrency-safe (0.6s gap between sends)
    """
    if not os.environ.get("TMUX"):
        sys.exit(0)

    try:
        server = get_server()
        current_pane = get_current_pane(server)
        current_window = current_pane.window
        session = current_window.session
        identity = current_window.name

        # Parse hook input (same for both paths)
        raw = sys.stdin.read()
        try:
            data = json.loads(raw)
            last_message = data.get("last_assistant_message", "")
        except json.JSONDecodeError as e:
            report_issue(
                f"stop-hook JSON parse failed: {e}\nraw: {raw[:300]}",
                component="stop-hook"
            )
            sys.exit(0)

        # ── Orchestrator path ──────────────────────────────────────────────
        if identity.startswith("orchestrator"):
            if last_message and NOTIFY_HUMAN_SIGNAL in last_message:
                _log(f"[{session.name}:orchestrator] NOTIFY HUMAN → calling notify-openclaw.sh")
                import subprocess
                try:
                    subprocess.run(
                        ["bash", str(NOTIFY_SCRIPT)],
                        timeout=30,
                        check=False   # don't fail if env vars missing
                    )
                except Exception as notify_err:
                    report_issue(
                        f"notify-openclaw.sh failed: {notify_err}",
                        component="notify"
                    )
            sys.exit(0)

        # ── Worker path ────────────────────────────────────────────────────
        if not last_message:
            sys.exit(0)

        send_to_orchestrator_safe(session, identity, last_message)
        _log(f"[{session.name}:{identity}] NOTIFY OK")

    except Exception as e:
        report_issue(str(e), component="stop-hook")
        sys.exit(0)  # never block Claude from exiting


def _log(message: str):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOG_DIR / "swarm.log", "a") as f:
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        f.write(f"[{ts}] {message}\n")
```

### 2.11 main() / argparse

```python
def main():
    parser = argparse.ArgumentParser(
        description="Swarm CLI — tmux-based multi-agent coordination"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # spawn
    p = sub.add_parser("spawn", help="Create worker window and send initial task")
    p.add_argument("name", help="Worker window name (e.g. worker-alice)")
    p.add_argument("task", help="Initial task to send")
    p.set_defaults(func=cmd_spawn)

    # send
    p = sub.add_parser("send", help="Send message to existing worker")
    p.add_argument("name")
    p.add_argument("message")
    p.set_defaults(func=cmd_send)

    # kill
    p = sub.add_parser("kill", help="Kill a worker window")
    p.add_argument("name")
    p.set_defaults(func=cmd_kill)

    # status
    p = sub.add_parser("status", help="Show all windows and pending issues")
    p.set_defaults(func=cmd_status)

    # ping
    p = sub.add_parser("ping", help="Send message to orchestrator")
    p.add_argument("message", nargs="?", default=None)
    p.set_defaults(func=cmd_ping)

    # report-issue
    p = sub.add_parser("report-issue", help="Log an issue for self-improving agent")
    p.add_argument("description")
    p.add_argument("--component", default="unknown")
    p.set_defaults(func=cmd_report_issue)

    # internal (called by hooks)
    sub.add_parser("session-start").set_defaults(func=lambda _: cmd_session_start())
    sub.add_parser("stop-hook").set_defaults(func=lambda _: cmd_stop_hook())

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
```

### Success Criteria Phase 2:
- [ ] `python3 ~/.claude/swarm/swarm.py --help` 显示所有子命令
- [ ] `python3 ~/.claude/swarm/swarm.py status` 列出当前 tmux 窗口
- [ ] `python3 ~/.claude/swarm/swarm.py report-issue "test" --component test` 在 `.issues/` 生成文件
- [ ] Python 3.9 语法检查：`python3 -m py_compile ~/.claude/swarm/swarm.py`

---

## Phase 3：改写 hooks 为两行 wrapper

### hooks/session-start.sh

```bash
#!/bin/bash
# Soft error mode: Claude must always start regardless of hook result
exec python3 ~/.claude/swarm/swarm.py session-start 2>/dev/null || true
```

### hooks/stop-hook.sh

```bash
#!/bin/bash
# Soft error mode: never block Claude exit
exec python3 ~/.claude/swarm/swarm.py stop-hook 2>/dev/null || true
```

**注意**：`settings.json` 的 hook 命令路径不变（`"command": "bash ~/.claude/hooks/session-start.sh"`）。

### Success Criteria Phase 3:
- [ ] 手动运行 `bash ~/.claude/hooks/session-start.sh`（在 tmux 内）输出 SWARM MODE ACTIVE block
- [ ] 手动运行 `echo '{"last_assistant_message":"test TASK_DONE"}' | bash ~/.claude/hooks/stop-hook.sh` 不报错
- [ ] 新建 Claude 会话，确认 session-start 输出正确角色

---

## Phase 4：改写 orchestrator.md + 更新 settings.json

### 4.0 settings.json 变更

从 Stop hooks 数组中移除 `notify-openclaw.sh`，防止每次 Claude stop 都发通知：

```json
"Stop": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": "bash ~/.claude/hooks/stop-hook.sh"
      }
    ]
  }
]
```

> 注意：非 tmux 环境下 stop-hook.py 会提前 exit(0)，notify-openclaw.sh 也不会被调用。
> 这是可接受的 tradeoff：非 swarm Claude 实例不再发通知，只有 orchestrator 显式 NOTIFY HUMAN 才发。

### 4.1 改写 orchestrator.md

删除所有内联 bash 示例，替换为 `swarm.py` 命令。核心变更：

```markdown
## Worker 生命周期管理

共享运行时：`/tmp/claude-swarm`

### 创建 worker
```bash
python3 ~/.claude/swarm/swarm.py spawn worker-alice "你的任务是：..."
```

### 给已有 worker 发新任务
```bash
python3 ~/.claude/swarm/swarm.py send worker-alice "新任务描述"
```

### 复用 worker（/clear 后分配新任务）
```bash
# 先在 worker 窗口发 /clear，再发新任务
python3 ~/.claude/swarm/swarm.py send worker-alice "/clear"
sleep 2
python3 ~/.claude/swarm/swarm.py send worker-alice "新任务描述"
```

### 回收 worker
```bash
python3 ~/.claude/swarm/swarm.py kill worker-alice
```

### 查看当前状态
```bash
python3 ~/.claude/swarm/swarm.py status
```

### Ping 自己（定时唤醒）
```bash
python3 ~/.claude/swarm/swarm.py ping "检查消息"
```

### 发现 swarm 设计问题
```bash
python3 ~/.claude/swarm/swarm.py report-issue "问题描述" --component orchestrator
```
```

**orchestrator.md 新增章节 — 通知 Human**：

```markdown
### 通知 Human（任务完成时）

当你判断整个任务已经完成、需要告知 human 时，在你的 **最后一条消息** 中包含大写的：

    NOTIFY HUMAN

stop-hook 会捕获到这个信号并发送通知。注意：
- 不要在等待 worker 回复的中间过程中输出此信号
- 每次完整任务结束时输出一次
- 它可以和正常的回复内容并存（signal 可以在消息末尾）
```

**同时更新 worker.md**，在结构化输出规则后加一条：
> **完成任务前**：运行 `git diff --stat HEAD` 并将修改的文件列表写入 NEXT_NEEDED，让 orchestrator 能够核对实际修改范围。

### Success Criteria Phase 4:
- [ ] `settings.json` Stop hooks 数组中不含 `notify-openclaw.sh`
- [ ] orchestrator.md 中不含 `tmux` 命令（`grep -c tmux orchestrator.md` 返回 0）
- [ ] orchestrator.md 中不含 `$SESSION` 变量引用
- [ ] orchestrator.md 包含 `NOTIFY HUMAN` 规则说明
- [ ] worker.md 包含 `git diff --stat` 规则

---

## Phase 5：self-improving agent 基础设施完整测试

### 5.1 .issues/ 格式验证

```bash
python3 ~/.claude/swarm/swarm.py report-issue "测试问题" --component test
ls ~/.claude/swarm/.issues/
cat ~/.claude/swarm/.issues/*.md
```

### 5.2 self-improving agent 在线时的路由测试

1. 在一个新 tmux 窗口中启动 Claude，手动 rename 为 `claude-self-improving`
2. 运行 `python3 ~/.claude/swarm/swarm.py report-issue "路由测试" --component test`
3. 确认消息出现在 `claude-self-improving` 窗口的输入框
4. 确认 `.issues/` 中同样有记录（双写）

### Success Criteria Phase 5:
- [ ] `.issues/` 文件格式正确（YAML frontmatter + markdown body）
- [ ] 无 self-improving agent 时：只写文件，无报错
- [ ] 有 self-improving agent 时：写文件 + ping 窗口，均成功

---

## 运行时目录结构（变更后）

```
/tmp/claude-swarm/
├── logs/
│   └── swarm.log           ← 结构化日志（替代 stop-hook.log）
└── runtime/
    └── last_orchestrator_send  ← 时间戳，用于并发保护

~/.claude/swarm/
├── swarm.py                ← 新增：统一 CLI
├── orchestrator.md         ← 改写：只含 swarm 命令
├── worker.md               ← 小改：增加 git diff 规则
├── self-improving.md       ← 不变
├── .issues/                ← 新增：运行时问题记录
│   └── YYYYMMDD-HHMMSS-component.md
└── bin/                    ← 删除（或保留空目录）
```

---

## 测试顺序建议

1. Phase 1（删除）→ 确认无残留引用
2. Phase 2（swarm.py）→ 单独测试每个子命令
3. Phase 3（hooks）→ 新开 tmux 窗口测试 session-start
4. Phase 4（文档）→ 阅读核查
5. Phase 5（issues）→ 端到端测试

---

## References

- 分析来源：本次对话中的系统性 review（2026-04-09）
- 现有 hooks：`~/.claude/hooks/session-start.sh`, `~/.claude/hooks/stop-hook.sh`
- libtmux 文档：https://libtmux.git-pull.com/
