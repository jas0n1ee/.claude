---
id: 005
date: 2026-04-07
component: stop-hook / session-start
severity: high
status: fixed
fix_commit: stop-hook.sh + session-start.sh: add -t "$TMUX_PANE" to tmux display-message
---

## 现象

orchestrator 的 stop hook 触发后，把 orchestrator 自己的最后输出误写进 worker-impl 的
TASK_DONE inbox，导致 orchestrator 收到自己输出伪装成的虚假 worker 汇报。

## 根因分析

`tmux display-message -p '#W'`（不带 `-t`）返回的是 tmux **客户端当前活跃窗口**，
而非 hook 进程所在窗口。用户切换到 worker-impl 窗口查看进度时，orchestrator 的
stop hook 恰好触发，`CURRENT_WINDOW` 拿到了 "worker-impl"，绕过了 orchestrator
的 early exit 判断，并把 orchestrator 的输出写进了 worker-impl 的 inbox。

```bash
# 错误：返回用户当前看的窗口
CURRENT_WINDOW=$(tmux display-message -p '#W')

# 正确：用 $TMUX_PANE 锁定 Claude 进程所在 pane
CURRENT_WINDOW=$(tmux display-message -p '#W' -t "$TMUX_PANE")
```

`$TMUX_PANE` 由 tmux 在创建 pane 时注入到 shell 环境，Claude 进程继承它，
hook 脚本再从 Claude 继承——始终指向 Claude 所在的那个 pane，不随用户切换而变化。

## 修复方案

stop-hook.sh 和 session-start.sh 中所有 `tmux display-message` 调用统一加
`-t "$TMUX_PANE"`，确保 SESSION 和 CURRENT_WINDOW 始终反映 Claude 进程实际所在的窗口。
