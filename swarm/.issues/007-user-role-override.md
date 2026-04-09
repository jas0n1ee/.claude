---
id: 007
date: 2026-04-08
component: orchestrator | self-improving
severity: medium
status: fixed
fix_commit: Updated skill.md to clarify user instruction precedence
---

## 现象

当用户明确告知 Claude"你是 self-improving agent"时，Claude 仍然按照 tmux 窗口名称自动检测身份（检测到 orchestrator），没有切换到用户指定的角色。

原始交互：
1. 用户说"你是claude-self-improving agent check your swarm role"
2. Claude 检测到当前窗口名为 orchestrator，于是继续扮演 orchestrator
3. 用户需要第二次明确指示才切换到 self-improving 身份

## 原始输出 / 关键片段

用户: "你是claude-self-improving agent check your swarm role"
Claude: (执行 tmux 检测) "IN_TMUX ... SESSION=_claude CURRENT_WINDOW=orchestrator"
Claude: 继续读取 orchestrator.md，回复 "**Role confirmed: Orchestrator**"

## 根因分析

1. CLAUDE.md 中的 Swarm 模式逻辑只在"启动时"执行，没有规定用户明确指令的优先级
2. 用户直接指定角色是一种明确的 context switch 意图，应该覆盖自动检测
3. 文档中缺少"用户明确指令 > 自动检测"的优先级规则

## 修复方案

在 skill.md 中添加规则：用户明确指定角色时，立即切换，覆盖自动检测结果。

文档更新内容：
- 在 "创建 worker" 或其他相关章节添加优先级说明
- 明确区分"启动时检测"和"运行中用户指令覆盖"两种场景
