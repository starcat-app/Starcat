# Git 分支与 Worktree 操作规范

本文规定 Starcat 主仓库中 Git 分支与 worktree 的创建、登记、同步、合并和清理流程。目标是让每个长期分支都有明确用途和归宿，避免误删未合并工作、遗忘远端分支或把用户的未提交修改留在废弃 worktree 中。

根目录 [`BRANCH.md`](../../BRANCH.md) 是当前分支用途登记表；Git refs、提交关系与 `git worktree list` 是分支是否存在及实际归属的事实来源。两者不一致时，先核对 Git 状态，再修正 `BRANCH.md`，不能依据过期文档直接执行删除。

本规范只约束 Starcat 主仓库。`supports/` 下的独立 Git 仓库必须在各自仓库中单独检查分支、worktree 和本地协作规则。

## 1. 分支职责

| 分支类型 | 职责 | 默认基线 | 默认归宿 |
|---|---|---|---|
| `main` | 远端稳定主线与发布基线 | 不适用 | 长期保留 |
| `dev` | 日常开发与功能集成主线 | `main` | 验收后进入 `main` |
| 专项开发分支 | 承载独立、跨会话或尚未达到可用状态的功能 | `dev` | 验收后合回 `dev` |
| hotfix 分支 | 修复当前稳定版本的紧急问题 | 由 dong4j 明确指定 | 合入稳定主线后同步回 `dev` |
| 远端遗留分支 | 尚未确认用途或合并情况的历史分支 | 不适用 | 审查后保留或删除 |

除发布或 hotfix 场景外，新开发分支默认从最新 `dev` 创建，不能无说明地从 `main`、旧提交或其他专项分支派生。

## 2. 命名规则

- dong4j 已指定分支名时使用指定名称，不擅自改名。
- Codex 创建的专项分支默认使用 `codex/<topic>`。
- Claude Code 创建的专项分支默认使用 `claude/<topic>`。
- 人工或共享功能分支可使用 `feature/<topic>`、`fix/<topic>`、`docs/<topic>`。
- `<topic>` 使用小写英文与 kebab-case，表达产品域或任务结果，不使用 `temp`、`test2`、`new` 等无意义名称。
- `main`、`dev` 和正在使用的长期分支禁止改名或复用为其他用途。

示例：

```text
codex/agent-iteration
claude/rag-evaluation
feature/browser-plugin
fix/oauth-callback
```

## 3. 操作前检查

任何创建、切换、同步、合并或删除操作前，必须先执行：

```bash
git status --short --branch
git branch --show-current
git worktree list --porcelain
```

涉及远端状态时，再执行：

```bash
git fetch --prune
```

同时检查根目录 `BRANCH.md`，确认：

1. 当前分支的用途和状态。
2. 目标分支是否已由其他 worktree 使用。
3. 当前工作区是否存在用户或其他 Agent 的未提交修改。
4. 本次操作是否获得 dong4j 明确授权。

只读审查不授权创建、切换、合并、删除或推送分支。方案讨论也不构成 Git 写操作许可。

## 4. 何时使用 Worktree

适合使用独立 worktree：

- 专项功能需要跨会话持续开发，同时必须保留 `dev` 作为日常工作目录。
- 两个不同分支需要并行开发或独立验证。
- 合并、迁移或大范围整改需要隔离工作区，避免污染当前未提交修改。
- dong4j 明确要求将功能停放在独立分支/worktree。

不应默认创建 worktree：

- 只读审查、问题解释或一次性短任务。
- 多个工具明确需要在同一分支协作。
- 当前任务可以在现有分支安全完成，且没有并行分支需求。
- 只是为了绕过脏工作区或隐藏未处理修改。

一个分支同一时间只能被一个 worktree 检出。worktree 是共享同一个 Git 对象库和 refs 的工作目录，不是独立 clone；在任意 worktree 创建、删除或移动分支都会影响整个仓库。

## 5. 创建分支与 Worktree

### 5.1 在当前工作区创建分支

确认当前工作区干净且基线正确后：

```bash
git switch dev
git switch -c codex/<topic>
```

### 5.2 创建独立 Worktree

新分支的 worktree 默认放在主仓库同级目录，名称使用 `Starcat-<topic>`：

```bash
git worktree add -b codex/<topic> ../Starcat-<topic> dev
```

为已有本地分支创建 worktree：

```bash
git worktree add ../Starcat-<topic> codex/<topic>
```

创建完成后必须立即：

1. 用 `git worktree list --porcelain` 验证分支归属。
2. 在 `BRANCH.md` 登记分支、用途、位置、状态和下一步。
3. 向 dong4j 报告分支说明，不得只回复“已创建”。

## 6. 强制分支说明

创建、切换或恢复长期分支/worktree 后，必须向 dong4j 提供：

```text
当前分支：codex/example
用途：实现……
基线：dev
Worktree：../Starcat-example
状态：开发中
后续归宿：验收后合并回 dev
```

如果分支已经与 `dev` 分叉，还要补充：

```text
同步状态：与 dev 双向分叉；继续开发前需要先合入最新 dev
```

这份说明必须与 `BRANCH.md` 一致。无法确认用途时，状态写为 `待审查`，不能自行猜测或删除。

## 7. BRANCH.md 登记规则

以下分支必须登记：

- 跨会话或长期存在的开发分支。
- 使用独立 worktree 的分支。
- 暂时停放但仍有未合并价值的分支。
- 仅存在于远端且尚未完成审查的分支。

同一次任务内创建、合并并删除的短期分支可以不登记，但删除前检查仍然必须执行。

登记至少包含：

| 字段 | 要求 |
|---|---|
| 分支 | 本地名或完整远端名 |
| 位置 | 本地、远端及 worktree |
| 用途 | 具体功能范围，不能只写“开发中” |
| 当前状态 | `开发中`、`长期保留`、`停放`、`待审查`、`已合并` 或 `已废弃` |
| 下一步 | 同步、继续开发、合并、审查或删除 |

分支合并或删除后，要把记录从“当前分支”移到“近期已清理分支”，写明是 Git 合并、语义覆盖还是方案废弃。不能只删除表格行而不保留处理结论。

## 8. 同步与合并

专项分支长期开发前，先判断它与 `dev` 的关系：

```bash
git rev-list --left-right --count dev...<branch>
git log --oneline --left-right dev...<branch>
```

默认通过 merge 将最新 `dev` 带入专项分支，避免对已经共享或长期存在的分支擅自改写历史：

```bash
git -C ../Starcat-<topic> merge dev
```

存在冲突时：

1. 先检查 merge 状态和冲突双方。
2. 保留用户及目标分支的有效改动。
3. 不使用 `git reset --hard`、`git checkout --` 或强制覆盖解决冲突。
4. 冲突解决完成后执行与改动风险匹配的测试。

合回 `dev` 前必须确认：

```bash
git status --short --branch
git log --oneline dev..<branch>
git diff --stat dev...<branch>
```

合并完成后验证：

```bash
git merge-base --is-ancestor <branch> dev
```

是否 squash、保留 merge commit 或使用其他策略，由 dong4j 的当前要求或既有仓库流程决定，不能擅自重写已共享历史。合并成功不等于获得 push 权限。

## 9. 删除分支与清理 Worktree

删除前必须同时确认：

1. 精确目标分支名，避免删除相似名称。
2. 分支是否仍被 worktree 使用。
3. worktree 是否存在修改、未跟踪文件或未提交提交。
4. 分支是否已合并，或其独有内容是否已被当前实现语义覆盖。
5. `BRANCH.md` 是否已记录审查结论。
6. dong4j 是否明确授权当前删除操作，尤其是远端分支。

检查命令：

```bash
git worktree list --porcelain
git rev-list --left-right --count dev...<branch>
git cherry dev <branch>
git diff --stat dev...<branch>
```

若分支不是 `dev` 的祖先，必须逐项审查独有代码、迁移、测试和文档；不能因为提交时间较旧就判断可以删除。

清理顺序：

```bash
git -C ../Starcat-<topic> status --short --branch
git worktree remove ../Starcat-<topic>
git branch -d <branch>
git worktree prune
```

删除远端分支必须单独获得授权：

```bash
git push origin --delete <branch>
git fetch --prune
```

禁止：

- 用 `rm -rf` 代替 `git worktree remove`。
- 对有修改或未跟踪文件的 worktree 使用强制删除。
- 未完成语义审查时使用 `git branch -D`。
- 为了清理分支而丢弃用户修改。
- 把“本地已删除”误报成“远端已删除”。

## 10. 并行协作约束

- 多个 Agent/工具在同一分支协作时，共用该分支已有 worktree，不为同一分支重复创建 worktree。
- 不在另一个 Agent 正在工作的 worktree 中切换分支。
- 发现目标文件已有未知修改时，先确认来源并避让，不把修改搬到其他分支后再静默覆盖。
- `supports/` 下独立仓库的分支操作必须在其仓库目录执行，不能把主仓库的分支状态当作其状态。
- 分支或 worktree 操作完成后，要报告实际执行结果；计划、命令草稿或部分成功不能表述为完成。

## 11. 完成检查

```text
[ ] 当前分支、基线和 worktree 归属已核对
[ ] 未覆盖或丢弃现有修改
[ ] 长期分支已登记到 BRANCH.md
[ ] 已向 dong4j 说明分支用途和后续归宿
[ ] 合并前已检查独有提交和 diff
[ ] 删除前已检查 Git 合并或语义覆盖
[ ] worktree 已通过 git worktree remove 安全清理
[ ] 本地和远端删除状态分别核实
[ ] 未经授权没有 push、删除远端分支或改写历史
```
