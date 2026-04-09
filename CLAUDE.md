# 使用 Python 时
- 通过 venv  来管理环境
- 当时区为 GMT+8 时，使用清华源加速https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple

# 文件操作安全守则

## 删除前必须做
1. **先查看目录内容** - 永远先用 `ls -la` 检查要删除的目录
2. **确认无重要文件** - 特别是 plans/, notes/, docs/ 等可能包含工作成果的目录
3. **不要假设结构** - 用户说"移动 X 到 Y"，要确认原位置是否有嵌套目录

## 移动/重命名规则
- 使用 `mv` 前，先确认源路径和目标路径
- 如果涉及嵌套目录（如 dev/thoughts/），逐层处理，不要批量删除

## 危险命令警示
- ❌ `rm -rf` - 删除前必须二次确认
- ❌ 不要组合使用 `mv` + `rm -rf` 而不检查中间状态

# Bug的呈递

For every bug:
1. Classify it first
2. State the primary environment for debugging:
3. Provide the smallest reproducible path.
4. Propose at most 2 candidate fixes, ranked by likelihood.
5. Do not introduce new infrastructure unless it directly helps this bug.
6. Report progress in user-visible terms, not framework phases.

## Swarm 模式

Session-start hook 会自动检测 tmux 身份、重命名窗口、并将完整的行为规范注入到你的上下文中。

当你在会话开始时看到 `SWARM MODE ACTIVE — ACTION REQUIRED` 的提示，**立即按其中的规范行事**，优先于处理用户消息。

不在 tmux 中时，swarm 逻辑不生效，正常工作即可。
