---
id: 008
date: 2026-04-08
component: stop-hook
severity: high
status: fixed
fix_commit: Updated stop-hook.sh with TMUX_PANE fallback logic
---

## 现象

`insta_toolset` session 的 worker-test4 完成了任务（输出了 TASK_DONE），但 orchestrator 没有收到消息。查看 stop-hook.log 发现大量空值记录：

```
[2026-04-07 16:34:35][:] INBOX WRITE: /home/jian/.claude/swarm/.inbox//orchestrator/.msg
```

`[:]` 表示 `$CURRENT_SESSION` 和 `$CURRENT_WINDOW` 都为空，导致 inbox 路径错误（`//orchestrator/.msg`）。

## 原始输出 / 关键片段

worker-test4 实际完成了任务：
```
● TASK_DONE
  Task 4: Metadata Extraction Only - COMPLETED
```

但 orchestrator inbox 目录不存在：
```bash
$ ls ~/.claude/swarm/.inbox/insta_toolset/orchestrator/
ls: cannot access ...: No such file or directory
```

## 根因分析

stop-hook.sh 第 6-7 行依赖 `$TMUX_PANE` 环境变量：
```bash
CURRENT_WINDOW=$(tmux display-message -p '#W' -t "$TMUX_PANE")
CURRENT_SESSION=$(tmux display-message -p '#S' -t "$TMUX_PANE")
```

验证发现 `TMUX_PANE` 不是 tmux 环境变量（`tmux showenv TMUX_PANE` 返回 `unknown variable`），而是 shell 进程继承的环境变量。当 stop hook 执行时，可能无法正确继承该变量，导致：
1. `tmux display-message -t ""` 执行失败或返回空值
2. inbox 路径组件缺失，写入失败或写入错误位置

## 修复方案

**根本原因**：`TMUX_PANE` 是 shell 环境变量，不是 tmux 环境变量（`tmux showenv TMUX_PANE` 返回 unknown variable）。Hook 执行时无法保证继承该变量。

**解决方案**：使用 `tmux display-message` 直接获取 pane ID，再推导 window/session：

```bash
# 获取当前 pane ID（不依赖 TMUX_PANE 环境变量）
CURRENT_PANE=$(tmux display-message -p '#D')
# 通过 pane ID 获取 window 和 session（稳定）
CURRENT_WINDOW=$(tmux display-message -t "$CURRENT_PANE" -p '#W')
CURRENT_SESSION=$(tmux display-message -t "$CURRENT_PANE" -p '#S')
```

关键区别：
- `#P` - pane 在 window 内的索引（0, 1, 2...）
- `#D` - pane 的唯一 ID（%7, %8...），跨 session 唯一

**注意**：`-t` 选项必须在 `-p` 之前，否则报错 "too many arguments"。

**修改文件**：
- `hooks/stop-hook.sh` - 使用稳定方法获取 pane/window/session
- `hooks/session-start.sh` - 同样修复
- `swarm/skill.md` - 添加 "稳定获取当前 Pane/Window/Session" 章节
