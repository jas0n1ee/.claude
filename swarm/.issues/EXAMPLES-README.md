# Swarm 负样本库

每个负样本是一个独立的 `.md` 文件，命名格式：`NNN-slug.md`（如 `001-worker-no-task-done.md`）。

---

## 文件格式模板

```
---
id: NNN
date: YYYY-MM-DD
component: orchestrator | worker | stop-hook | session-start
severity: low | medium | high
status: open | fixed
fix_commit: (修复后填写，或引用对应文档改动)
---

## 现象

（描述出现了什么问题，发生在什么阶段，表现是什么）

## 原始输出 / 关键片段

（粘贴 worker 或 orchestrator 的相关输出，或行为描述）

## 根因分析

（问题出在哪个规则缺失、哪个约定不清晰、或哪个 hook 逻辑有误）

## 修复方案

（对 orchestrator.md / worker.md / hooks/ 做了什么改动，或建议做什么改动）
```

---

## 负样本索引

| ID | 日期 | 组件 | 摘要 | 状态 |
|----|------|------|------|------|
| [001](001-long-text-bracketed-paste.md) | 2026-04-07 | orchestrator | 长文本 send-keys 被 bracketed paste 吞掉 Enter，不自动执行 | fixed |
| [002](002-stop-hook-no-orchestrator-window.md) | 2026-04-07 | stop-hook | 无 orchestrator 窗口时 stop hook 报 can't find window 错误 | fixed |
| [003](003-stop-hook-silent-failure.md) | 2026-04-07 | stop-hook | stop hook 未触发或 tmux send-keys 静默失败，无任何日志可追溯 | fixed |
| [004](004-inbox-file-based-delivery.md) | 2026-04-07 | stop-hook/session-start | tmux send-keys 作为唯一 channel 不可靠，改为 file-based inbox + 推送通知双 channel | fixed |
| [005](005-tmux-display-message-wrong-window.md) | 2026-04-07 | stop-hook/session-start | tmux display-message 不带 -t 返回活跃窗口而非 Claude 所在窗口，导致 orchestrator 输出被误写为 worker TASK_DONE | fixed |
| [006](006-stop-hook-fires-on-every-response.md) | 2026-04-07 | stop-hook | stop hook 在每次 Claude 响应结束时都触发，unstructured fallback 产生大量噪音 inbox | fixed |
| [007](007-user-role-override.md) | 2026-04-08 | orchestrator/self-improving | 用户明确指定角色时应覆盖自动检测的身份 | fixed |
| [008](008-stop-hook-empty-session-window.md) | 2026-04-08 | stop-hook | TMUX_PANE 环境变量缺失导致 session/window 获取为空 | fixed |
| [009](009-inbox-permission-interrupt.md) | 2026-04-08 | stop-hook/orchestrator | .claude 目录敏感权限拦截 inbox 操作，打断 workflow | fixed |
| [010](010-worker-misidentified-as-orchestrator.md) | 2026-04-08 | session-start.sh | grep 精确匹配导致 orchestrator- 变体无法识别，worker 误判身份 | fixed |
