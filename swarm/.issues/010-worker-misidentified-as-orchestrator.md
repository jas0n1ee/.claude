---
id: 010
date: 2026-04-08
component: session-start.sh / CLAUDE.md
severity: high
status: fixed
fix_commit: Updated session-start.sh to use grep -cE '^orchestrator(-|$)' for flexible matching
---

## 现象

在另一台机器上，worker 会把自己当成 orchestrator，导致 swarm 模式混乱。

## 根因分析

在 `session-start.sh` 和 `CLAUDE.md` 中，检测 orchestrator 窗口的逻辑是：

```bash
HAS_ORCHESTRATOR=$(tmux list-windows -t "$SESSION" -F '#W' | grep -c '^orchestrator$')
```

这个正则表达式 `^orchestrator$` 要求窗口名**精确匹配** `orchestrator`。

如果 orchestrator 窗口名是以下任何一种变体，worker 会误判为没有 orchestrator：
- `orchestrator-` (tmux 自动添加的后缀)
- `orchestrator-1`
- `orchestrator_1`
- `orchestrator (1)`

此时 worker 会执行：
```bash
if [ "$HAS_ORCHESTRATOR" = "0" ]; then
  tmux rename-window -t "$SESSION:$CURRENT_WINDOW" orchestrator
  echo "SWARM_ROLE=orchestrator (just promoted, window renamed)"
```

## 可能触发场景

1. **手动创建窗口**：用户手动创建名为 `orchestrator` 的窗口，但 tmux 或其他工具自动添加了后缀
2. **窗口重命名历史**：orchestrator 窗口曾经被重命名过，留下了变体名称
3. **多个 orchestrator 尝试**：用户尝试创建第二个 orchestrator 窗口（如 `orchestrator-1`）

## 修复方案

方案1：放宽匹配条件，允许 `orchestrator` 前缀
```bash
# 匹配以 orchestrator 开头的窗口名
HAS_ORCHESTRATOR=$(tmux list-windows -t "$SESSION" -F '#W' | grep -c '^orchestrator')
```

方案2：使用更明确的匹配（推荐）
```bash
# 匹配 orchestrator 或 orchestrator-* 的变体
HAS_ORCHESTRATOR=$(tmux list-windows -t "$SESSION" -F '#W' | grep -cE '^orchestrator(-|$)')
```

**需要更新的文件**：
- `hooks/session-start.sh` - HAS_ORCHESTRATOR 检测逻辑
- `CLAUDE.md` - Swarm 模式下的检测逻辑

**额外建议**：
考虑在 session-start.sh 中添加日志，记录检测到的窗口列表，便于调试：
```bash
# 调试日志（可选）
echo "[DEBUG] Windows in session: $(tmux list-windows -t "$SESSION" -F '#W' | tr '\n' ', ')" >> ~/.claude/swarm/.logs/session-start.log
```
