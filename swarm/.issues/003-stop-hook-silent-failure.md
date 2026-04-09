---
id: 003
date: 2026-04-07
component: stop-hook
severity: high
status: fixed
fix_commit: hooks/stop-hook.sh 加日志；orchestrator.md 加 best-effort 说明和 pane capture 指引
---

## 现象

worker 完成任务后，orchestrator 未收到 TASK_DONE 汇报。worker 窗口中也未看到 stop hook 执行失败的提示。orchestrator 发给 claude-self-improving 的 tmux 消息也未送达，说明 tmux send-keys 本身存在静默失败的风险。

## 原始输出 / 关键片段

```
# orchestrator 窗口：
# （无任何 TASK_DONE 汇报）

# worker 窗口：
# （无 stop hook 错误提示）
```

orchestrator 侧描述：
> "我也已经把它一并发给 claude-self-improving 窗口了，它会帮你改进这个 swarm 机制。"
> （但 claude-self-improving 未收到）

## 根因分析

两个独立风险叠加：

1. **stop hook 本身可能未触发**：Claude 异常退出、hook 脚本报错等均可导致 hook 不执行，且无任何日志可追溯
2. **tmux send-keys 可能静默失败**：目标 pane 未就绪、session 状态异常、窗口名不匹配等，tmux 不一定返回非零退出码，失败无记录

原有代码缺乏任何日志，事后无法判断：hook 是否触发？触发了是否执行到 send-keys？send-keys 是否成功？

## 修复方案

### 1. stop-hook.sh 加完整日志

每次执行记录到 `~/.claude/swarm/.logs/stop-hook.log`：
- hook 触发时间、session、窗口名
- SKIP 原因（无 orchestrator 窗口）
- 发送内容
- send-keys 成功或失败及退出码

### 2. orchestrator.md 加 best-effort 说明

在"接收 TASK_DONE 汇报"章节开头明确：stop hook 不保证送达，不能作为唯一信号。

### 3. orchestrator.md 加主动确认章节

当 TASK_DONE 未到达时，用 `tmux capture-pane` 主动查看 worker 状态，并知道如何查看 stop hook 日志。
