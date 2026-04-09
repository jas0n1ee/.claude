---
id: 009
date: 2026-04-08
component: stop-hook / orchestrator
severity: high
status: fixed
fix_commit:
---

## 现象

当 worker 尝试写入或删除 `.claude/swarm/.inbox/` 下的文件时，Claude Code 弹出敏感文件权限确认对话框：

```
Claude requested permissions to edit /home/jason/.claude/swarm/.inbox/insta_toolset/worker-test4-metadata/orchestrator.msg which is a sensitive file.

Do you want to proceed?
❯ 1. Yes
  2. Yes, and always allow access to worker-test4-metadata/ from this project
  3. No
```

这打断了整个自动化 workflow，worker 无法自主完成 inbox 写入/清理。

## 根因分析

`.claude/` 目录被 Claude Code 视为敏感区域（包含配置、hooks 等），对其中文件的写入/删除操作会触发权限确认。

inbox 机制设计初衷是让 worker 能自主、无阻塞地：
1. 读取 orchestrator 发来的任务 (`orchestrator.msg`)
2. 写入 TASK_DONE 汇报 (`../orchestrator/{worker}.msg`)
3. 清理已读消息

但敏感目录限制违背了这一设计目标。

## 修复方案

将 inbox 根目录从 `~/.claude/swarm/.inbox/` 迁移到 `/tmp/claude-swarm/inbox/`：

```bash
# 新路径结构
/tmp/claude-swarm/inbox/{session}/{identity}/{sender}.msg

# 示例
/tmp/claude-swarm/inbox/insta_toolset/worker-test4/orchestrator.msg
/tmp/claude-swarm/inbox/insta_toolset/orchestrator/worker-test4.msg
```

**已更新的文件**：
- `hooks/stop-hook.sh` - INBOX_FILE 路径
- `hooks/session-start.sh` - INBOX_DIR 路径
- `swarm/skill.md` - 文档中的路径示例
- `swarm/orchestrator.md` - inbox 路径说明

**清理策略**：
`/tmp` 在系统重启后会清空，符合 inbox 的临时性质。如需持久化，可考虑 `/var/tmp/` 或定期清理脚本。

**注意**：worker 不应主动删除 inbox 文件，标记已读的操作由 orchestrator 或 session-start hook 处理。
