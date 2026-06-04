# Multica 中使用 Git Worktree 进行任务开发

## 1. Git Worktree 基础

### 1.1 什么是 Git Worktree

Git Worktree 是 Git 内置的多工作目录功能，允许在同一个仓库的不同目录中同时处理多个分支。每个 worktree 都是仓库的完整克隆，但共享 Git 历史（.git 对象），因此：

- **磁盘空间高效**：新增 worktree 只需复制 HEAD引用和工作文件，不重复克隆完整历史
- **分支隔离**：各 worktree 相互独立，可同时在多个分支上工作而无需切换
- **快速切换**：通过简单的目录切换即可在不同任务间跳转

### 1.2 核心命令

```bash
# 创建新的 worktree（同时创建对应分支）
git worktree add <path> -b <branch-name>

# 创建 worktree 并指定已有分支
git worktree add <path> <branch-name>

# 列出所有 worktree
git worktree list

# 查看 worktree 状态
git worktree list --porcelain

# 删除已完成任务的 worktree
git worktree remove <path>

# 清理已删除 worktree 的孤立分支
git worktree prune
```

---

## 2. Multica 与 Git Worktree 的关系

### 2.1 Multica 已内置 Worktree 支持

**重要**：Multica 的 `multica repo checkout` 命令本身就是基于 Git Worktree 实现的：

```bash
multica repo checkout https://github.com/dong4j/Starcat
# 输出示例：
# Checked out https://github.com/dong4j/Starcat → /path/to/workdir/Starcat (branch: agent/claude/2a1cccfe)
```

当你执行 `multica repo checkout` 时：

1. Multica 在工作目录下创建了仓库的 worktree
2. 自动生成了一个专属分支（如 `agent/claude/2a1cccfe`）
3. 这个 worktree 与主仓库分支完全隔离

### 2.2 为什么适合 Multica 任务开发

| 场景 | 传统方式的问题 | Worktree 优势 |
|------|----------------|---------------|
| 并行处理多个任务 | 需要频繁切换分支、stash 改动 | 每个任务独立目录，互不干扰 |
| 任务中断恢复 | 切换分支可能丢失上下文 | 保留完整工作状态在对应目录 |
| 代码评审 | review 和开发混在一起 | 干净的 review 分支 vs 开发分支 |
| 实验性探索 | 担心污染主分支 | 在独立 worktree 尝试，随时可删 |

---

## 3. Multica + Git Worktree 使用流程

### 3.1 基础流程：使用 Multica 内置命令

这是最简单的方式，Multica 自动处理 worktree 创建和分支管理：

```bash
# 1. 拉取仓库（Multica 自动创建 worktree + 专属分支）
multica repo checkout https://github.com/dong4j/Starcat

# 2. 在对应目录中进行开发
cd Starcat
# ... 做开发 ...

# 3. 提交时确保 commit message 包含任务编号
git add .
git commit -m "feat: 实现某功能 (HOM-155)"
```

### 3.2 进阶流程：手动管理额外 Worktree

当需要**在同一个仓库并行开发多个任务**时，可以在 Multica 创建的 worktree 基础上再创建额外的 worktree：

```bash
# 假设 multica repo checkout 已经创建了主 worktree
# 主 worktree 路径：./Starcat（分支：agent/claude/2a1cccfe）

# 1. 在主 worktree 中创建新分支并推送（如果需要多人协作）
cd Starcat
git push -u origin agent/claude/2a1cccfe

# 2. 为当前任务创建额外的 worktree（用于并行处理其他任务）
#    注意：避免在 worktree 目录内再创建 worktree
cd ..
git worktree add ./starcat-feature-xxx -b feature/xxx
# 或使用绝对路径
git worktree add /path/to/starcat-feature-xxx -b feature/xxx

# 3. 在新的 worktree 中开发
cd ../starcat-feature-xxx
# ... 开发新功能 ...

# 4. 完成后合并回主分支
git checkout agent/claude/2a1cccfe  # 切换到主 worktree
git merge feature/xxx               # 合并功能分支
git branch -d feature/xxx           # 删除功能分支
```

### 3.3 流程图

```
                    ┌─────────────────────────────────────┐
                    │         Git Repository              │
                    │   (共享 .git 对象存储)              │
                    └──────────┬──────────────────────────┘
                               │
           ┌───────────────────┼───────────────────┐
           │                   │                   │
    ┌──────▼──────┐     ┌──────▼──────┐    ┌──────▼──────┐
    │  Worktree 1 │     │  Worktree 2 │    │  Worktree 3 │
    │ (Multica)   │     │ (feature-A) │    │ (feature-B) │
    │ agent/claude│     │ feature/A   │    │ feature/B   │
    │ /2a1cccfe   │     │             │    │             │
    └─────────────┘     └─────────────┘    └─────────────┘
```

---

## 4. 注意事项

### 4.1 Worktree 命名规范

推荐使用有意义的命名，便于识别用途：

```bash
# ✅ 推荐格式
starcat-feature-auth          # 功能开发
starcat-bugfix-123            # Bug 修复
starcat-refactor-ui           # 重构任务

# ❌ 避免
worktree1                     # 无意义
temp                          # 模糊
new-branch                    # 不清晰
```

### 4.2 避免在 Worktree 内创建 Worktree

Git 不支持嵌套 worktree（一个 worktree 目录内不能再创建 worktree）。如果需要更多并行分支：

1. **从主仓库创建**（推荐）：
   ```bash
   git worktree add ../starcat-feature-xxx -b feature/xxx
   ```

2. **使用绝对路径**避免路径混乱：
   ```bash
   git worktree add /Users/dong4j/starcat-feature-xxx -b feature/xxx
   ```

### 4.3 清理已完成任务的 Worktree

任务完成后及时清理，释放磁盘空间：

```bash
# 1. 确认没有未提交的更改
git status

# 2. 安全删除（如果分支已合并）
git worktree remove ./starcat-feature-xxx

# 3. 如果有未合并的更改，使用 --force（谨慎！）
git worktree remove ./starcat-feature-xxx --force

# 4. 清理孤立的 worktree 引用
git worktree prune

# 5. 确认清理结果
git worktree list
```

### 4.4 多任务并行时的分支管理策略

| 策略 | 适用场景 | 示例 |
|------|----------|------|
| **扁平分支** | 任务数量少（≤3） | `feature/auth`, `feature/search` |
| **前缀分组** | 任务数量中等（4-10） | `feat/auth`, `feat/search`, `fix/ui` |
| **按任务 ID** | 需要精确追踪 | `task/HOM-155`, `task/HOM-156` |

---

## 5. 相关命令参考

### 5.1 基础操作

```bash
# 查看所有 worktree
git worktree list
# 输出示例：
# /path/to/main           ABC1234 [main]
# /path/to/feature-auth   DEF5678 [feature/auth]
# /path/to/starcat-bugfix GHI9012 [bugfix/123]

# 创建 worktree（基于新分支）
git worktree add ../starcat-feature-xxx -b feature/xxx

# 创建 worktree（基于已有分支）
git worktree add ../starcat-feature-xxx feature/xxx
```

### 5.2 进阶操作

```bash
# 查看 worktree 详情（含分支信息）
git worktree list --porcelain

# 查看指定 worktree 的分支
git worktree list --porcelain | grep <path>

# 移动 worktree 到新位置（不常用）
git worktree move <old-path> <new-path>

# 锁定/解锁 worktree（防止意外删除）
git worktree lock <path>
git worktree unlock <path>
```

### 5.3 清理与维护

```bash
# 清理孤立的 worktree 引用
git worktree prune

# 自动清理（推荐在 .git/config 中配置）
git config gc.worktreePruneExpire 7.days.ago
```

---

## 6. 常见问题

### Q1: 删除 worktree 会丢失代码吗？

**不会**。删除 worktree 只是移除该目录对仓库的引用。只要代码已经 commit 到对应分支，代码是安全的。如果有未 commit 的更改，Git 会阻止删除（除非用 `--force`）。

### Q2: 一个仓库可以创建多少个 worktree？

**没有硬性限制**。但每个 worktree 都会占用磁盘空间，且太多 worktree 会让 `git worktree list` 变得难以管理。建议控制在 5-10 个以内。

### Q3: worktree 和 clone 有什么区别？

| 特性 | Worktree | Clone |
|------|----------|-------|
| 磁盘占用 | 极小（仅复制工作文件） | 大（完整历史） |
| 创建速度 | 快（秒级） | 慢（取决于仓库大小） |
| 共享历史 | ✅ 是 | ❌ 否 |
| 独立分支 | ✅ 是 | ✅ 是 |
| 适用场景 | 多分支并行开发 | 完整备份、CI/CD |

### Q4: 如何让 Multica 使用已有的 worktree？

Multica 的 `multica repo checkout` 会自动创建新的 worktree。如果想复用已有的 worktree，可以：

```bash
# 直接在已有的 worktree 目录中工作
cd /path/to/your/worktree
git checkout -b agent/claude/new-session
# ... 进行开发 ...
```

Multica 本身不强制要求特定的目录结构。

---

## 7. Multica 标准工作流程

### 7.1 完整生命周期

```
main 分支
    │
    ├── 每个新任务 = 新分支（如 agent/claude/xxx）
    │       │
    │       └── Agent 在该分支开发 → 推送 → 创建 PR
    │
    └── 人工审阅 → 合并到 main
```

### 7.2 分支与 Worktree 清理

**问题：本地分支会被主动删除吗？**

**不会**。Multica 不会自动删除已完成的分支和 worktree。PR 合并后，分支和 worktree 仍然保留在本地。

**什么时候应该删除？**

建议在 PR 合并后手动清理：

```bash
# 1. 删除 worktree（目录）
git worktree remove 2a1cccfe/workdir/Starcat

# 2. 删除远程分支（可选）
git push origin --delete agent/claude/2a1cccfe

# 3. 删除本地分支
git branch -D agent/claude/2a1cccfe
```

> ⚠️ **注意**：由于 `multica repo checkout` 创建的 worktree 路径是 `2a1cccfe/workdir/Starcat`，删除这个 worktree 后，该任务的工作目录就没了。如果想保留代码备份，可以只删除 worktree 引用，保留目录。

### 7.3 PR 审核中继续修改

**问题：PR 审核中需要继续修改，用新分支还是原分支？**

**继续用原分支**，原因：
- PR 已经建立，原分支的 commits 会自动追加到现有 PR
- 避免创建多个 PR 导致混乱

操作方式：
```bash
# 在原 worktree 中继续工作
cd 2a1cccfe/workdir/Starcat
git pull origin agent/claude/2a1cccfe  # 拉取最新（如果有其他改动）
# ... 继续修改 ...
git add . && git commit -m "fix: 审核反馈修改 (HOM-155)"
git push origin agent/claude/2a1cccfe
```

### 7.4 当前仓库结构示意

```
bare repo (bare)
    │
    └── worktree: ./2a1cccfe/workdir/Starcat
            └── 分支: agent/claude/2a1cccfe (已合并到 main)
```

---

## 8. 最佳实践总结

1. **日常任务**：直接使用 `multica repo checkout`，无需手动管理 worktree
2. **并行开发**：通过 `git worktree add` 在主仓库外创建额外的 worktree
3. **及时清理**：任务完成后立即删除不再需要的 worktree
4. **命名规范**：使用有意义的目录和分支名，便于识别
5. **commit 习惯**：确保每次 commit 包含任务编号（如 HOM-155），便于追溯
6. **审核期间**：继续在原分支修改，commits 会自动追加到已有 PR

---


## Multica + Git Worktree 正确流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                        阶段 1：开始任务                              │
└─────────────────────────────────────────────────────────────────────┘

# Multica 自动创建 worktree + 分支
multica repo checkout https://github.com/dong4j/Starcat
# → 自动创建 worktree: ./Starcat
# → 自动创建分支: agent/claude/2a1cccfe

cd Starcat
git status  # 确认在正确的分支上

───────────────────────────────────────────────────────────────────────

┌─────────────────────────────────────────────────────────────────────┐
│                        阶段 2：开发迭代                              │
└─────────────────────────────────────────────────────────────────────┘

# 开发代码...
git add .
git commit -m "feat: 实现功能 (HOM-155)"

# 推送分支（即使还在开发中）
git push -u origin agent/claude/2a1cccfe

# 可选：创建 PR（草稿状态，不用等"完成"）
gh pr create --base main --head agent/claude/2a1cccfe --title "feat: 实现功能" --draft

───────────────────────────────────────────────────────────────────────

┌─────────────────────────────────────────────────────────────────────┐
│                     阶段 3：审核反馈 → 修改                          │
└─────────────────────────────────────────────────────────────────────┘

# 审核中有反馈？继续在同一个分支上修改！
git add .
git commit -m "fix: 反馈修改 (HOM-155)"
git push origin agent/claude/2a1cccfe
# ↑ commits 自动追加到已有 PR，不用创建新 PR！

───────────────────────────────────────────────────────────────────────

┌─────────────────────────────────────────────────────────────────────┐
│                     阶段 4：合并 & 清理                              │
└─────────────────────────────────────────────────────────────────────┘

# 1. 在 GitHub 网页合并 PR（或用 gh pr merge）

# 2. 同步本地分支到最新的 main
git fetch origin
git checkout main
git pull origin main

# 3. 清理已完成的 worktree（可选）
git worktree list
git worktree remove ./Starcat
git branch -d agent/claude/2a1cccfe
git push origin --delete agent/claude/2a1cccfe  # 删除远程分支

───────────────────────────────────────────────────────────────────────

┌─────────────────────────────────────────────────────────────────────┐
│                     错误做法 ❌（避免）                               │
└─────────────────────────────────────────────────────────────────────┘

# 错误1：为同一个任务创建多个 PR
gh pr create ...  # PR #1
gh pr create ...  # PR #2 ❌ 会冲突！

# 错误2：PR 合并后不同步就推送新提交
git push origin agent/claude/2a1cccfe  # ❌ 分支落后 main

# 正确做法：PR 合并后先同步
git fetch origin
git merge origin/main  # 合并 main 到当前分支
git push origin agent/claude/2a1cccfe
```

---

## 一图流总结

```
Agent 任务周期：
                                    
  multica repo checkout               
         │                           
         ▼                           
  ┌─────────────┐                   
  │  开发分支    │  ◀── 在这里开发   
  │ agent/claude│                   
  │ /2a1cccfe   │                   
  └──────┬──────┘                   
         │                           
         │ git commit + push         
         ▼                           
  ┌─────────────┐                   
  │  PR (草稿)  │  ◀── 可以提前创建 
  └──────┬──────┘                   
         │                           
         │ 审核反馈?                 
         │ (继续提交)               
         ▼                           
  ┌─────────────┐                   
  │   合并 PR   │  ◀── 人工在 GitHub 
  └──────┬──────┘                   
         │                           
         │ git fetch + merge         
         ▼                           
  ┌─────────────┐                   
  │   清理分支   │  ◀── git worktree 
  │   & worktree│      remove       
  └─────────────┘                   
```



*本文档关联任务：[HOM-155](mention://issue/d32c6290-356e-4e68-86f8-873fbf55b9e0)*
