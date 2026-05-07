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

# Docker 使用

- 在使用 Docker 的时候，永远要注意 User ID 与 Group ID，不然这个 Docker 命令运行生成的产物，其所有权可能归属于 root 而不属于当前用户。这会导致后面需要 sudo 权限才可以处理，会非常麻烦。

# Bug的呈递

For every bug:
1. Classify it first
2. State the primary environment for debugging:
3. Provide the smallest reproducible path.
4. Propose at most 2 candidate fixes, ranked by likelihood.
5. Do not introduce new infrastructure unless it directly helps this bug.
6. Report progress in user-visible terms, not framework phases.

## Swarm 模式

Swarm 已迁移为独立 skill：`~/.agents/skills/swarm`。

Claude Code 不再通过 SessionStart hook 自动注入 Swarm 规范。需要使用 Swarm 时，通过 `/skills` 或正常 skill 选择加载 `swarm`。

Claude worker 的 Stop hook 仅负责把 worker 最后一条消息回传给当前 tmux session 的 orchestrator；Swarm runtime 统一调用 `python3 ~/.agents/skills/swarm/scripts/swarm.py --engine claude ...`。
