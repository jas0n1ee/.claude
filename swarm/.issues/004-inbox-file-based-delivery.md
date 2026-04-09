---
id: 004
date: 2026-04-07
component: stop-hook / session-start / orchestrator
severity: high
status: fixed
fix_commit: stop-hook.sh + session-start.sh + orchestrator.md
---

## 现象

orchestrator 建议用 `tmux capture-pane` 主动查看 worker 输出来弥补 stop hook 丢失的问题。这个方向是错误的：

1. 把 worker 的大量输出引入 orchestrator context，造成污染
2. 要求 orchestrator 主动 poll，破坏了 push-based 的设计
3. 根本原因（tmux send-keys 不可靠）没有被解决

## 根因分析

stop hook 用 `tmux send-keys` 作为唯一 delivery channel，而该 channel 本身不可靠（静默失败），且没有持久化。消息丢失后无任何恢复手段。

## 修复方案：file-based inbox（IM read flag 模式）

参考 IM 系统的 read receipt 设计：

- **文件存在 = 未读消息**
- **文件删除 = 已读/已处理**

### 目录结构
```
~/.claude/swarm/.inbox/{session}/{worker}.msg
```

### stop-hook.sh
- **主 channel**：先写 inbox 文件（可靠，持久化）
- **次 channel**：再做 tmux send-keys 推送通知（best-effort）
- 两个 channel 独立，推送失败不影响消息持久化

### session-start.sh
- orchestrator 启动时自动扫描 inbox
- 有未读消息则作为 system-reminder 输出，自动投递
- orchestrator 无需主动 poll，消息由 harness 注入

### orchestrator.md
- 处理完 TASK_DONE 后主动 rm inbox 文件（标记已读）
- 移除 capture-pane 相关指引
- 说明推送丢失时的恢复机制（重启自动投递）
