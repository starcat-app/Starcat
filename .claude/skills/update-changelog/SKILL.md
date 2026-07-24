---
name: update-changelog
description: >
  Update Starcat changelog documents in supports/starcat-pro/ by reading ALL git commits
  from the main Starcat project and generating categorized release notes in both English
  and Chinese. Use this skill whenever the user wants to update changelog, release notes,
  update records, or sync the changelog with recent commits. Also trigger when the user
  mentions CHANGELOG.md, CHANGELOG-ZH.md, release notes update, or asks to summarize
  recent changes for the next version.
---

# Update Starcat Changelog

Read ALL git commits from the main Starcat project since the last version tag, then update
`CHANGELOG.md` (English) and `CHANGELOG-ZH.md` (Chinese) in `supports/starcat-pro/`.

## File Locations

| File | Path |
|------|------|
| Changelog (EN) | `supports/starcat-pro/CHANGELOG.md` |
| Changelog (ZH) | `supports/starcat-pro/CHANGELOG-ZH.md` |
| Git repo (source) | Starcat root (the Xcode project) |

---

## Step 0: Ask for Version Number (MANDATORY — Do This FIRST)

**This is a blocking step.** Before reading any git log or touching any file, you MUST
know the target version number. If the user did not provide one in their invocation,
immediately ask:

> "Which version number should I use for this changelog entry? (e.g., `1.2.0`, `1.1.1`)"

Do NOT proceed to Step 1 until the user answers. Do NOT guess or assume a version number.

If the user's invocation already includes a version number (e.g., "update changelog for 1.2.0"),
validate that it matches `X.Y.Z` format. If it doesn't, ask the user to provide a valid format.

The version number must be in `X.Y.Z` format (semantic versioning) because `release-direct.sh`
requires this format.

---

## Step 1: Determine Commit Range

```bash
# Latest tag
git tag --sort=-creatordate | head -1

# All commits since that tag (NO filtering, NO skip)
git log <latest-tag>..HEAD --oneline --no-merges

# Count
git log <latest-tag>..HEAD --oneline --no-merges | wc -l
```

If no tag exists, start from the first commit.

If there are 0 commits since the latest tag, stop and tell the user:
"No new commits since <latest-tag>. There's nothing to add to the changelog."

---

## Step 2: Read EVERY Commit Message (Do NOT Skip Any)

```bash
# Full messages for ALL non-merge commits — every single one
git log <latest-tag>..HEAD --format="---COMMIT---%n%h%n%s%n%b" --no-merges
```

**Critical rule**: Read EVERY commit first. Then in Step 3a, filter out non-user-facing
changes. Don't skip commits at read time — some commits with non-standard prefixes may
still describe user-visible changes. The filtering happens AFTER reading, based on content.

---

## Step 3: Filter and Categorize

### 3a: EXCLUDE Non-User-Facing Changes First

**The changelog is for end users.** Before categorizing, filter OUT commits that have
zero user-visible impact. These commits are NOT included in the changelog at all:

| Exclude | Examples |
|---------|----------|
| Internal documentation | `docs:` commits, 审查报告, 进度文档, 专项 checklist |
| Build/config tooling | appcast.xml updates, CI scripts, .gitignore changes, sync scripts |
| Developer-only changes | Test fixes, worktree recovery, project file tweaks, code review artifacts |
| Meta/process commits | 回填进度, 记录验证, 补充审查, 落档方案, 同步口径 |

**Test**: "Would a Starcat user notice this change when using the app?" If no → exclude.

### 3b: Categorize Remaining Commits

Read the full message (subject + body) and classify into one of THREE categories:

| Category | How to recognize |
|----------|-----------------|
| **New** | New feature, new capability, new UI element, new workflow — something the user couldn't do before |
| **Improved** | Enhancement, optimization, polish, refactor, style improvement — something that got better but existed before |
| **Fixed** | Bug fix, correction, restoration — something that was broken and now works |

**Classification by Chinese keywords** (most commits use Chinese messages):

| Keywords | → Category |
|----------|-----------|
| `新增` `添加` `实现` `支持` `接入` `集成` `创建` `扩展` `放开` | **New** |
| `优化` `改进` `增强` `调整` `重构` `统一` `收敛` `简化` `完善` `升级` `迁移` `拆分` `还原` `隐藏` | **Improved** |
| `修复` `修正`(bug) `恢复`(误删) `解决` `避免` | **Fixed** |

**When the prefix and content disagree**, trust the content.

**For English-prefix commits** (`feat:`, `fix:`, `refactor:`, `perf:`, `style:`):
- `feat:` → **New**
- `fix:` → **Fixed**
- `refactor:` `perf:` `style:` → **Improved**

---

## Step 4: Group Related Commits into Topic Bullets

This is the most important step. Don't write one bullet per commit — **merge related commits
into a single, comprehensive bullet point** that tells a coherent user story.

### How to group

1. Scan all commits and identify topic clusters (e.g., "Onboarding flow", "Agent workbench",
   "Landing page / DMG", "RAG workbench", "Sidebar / navigation")
2. For each cluster, write ONE bullet that synthesizes all related commits
3. A cluster typically has 2-8 commits; merge them into 1-2 bullets

### Example: multiple commits → one bullet

```
Commits:
  - feat(starcat): 新增新手引导返回功能及流程优化
  - feat(starcat): 新增调试模式下主窗口新手引导开关及流程优化
  - feat(starcat): 优化新手引导流程与分享指引交互
  - feat(starcat): 重构新手引导流程并扩展详情页与分享步骤

→ ONE bullet:
  EN: Onboarding flow: Back navigation, debug-mode controls, share guidance, and extended detail-page and sharing steps.
  ZH: 新手引导流程：支持返回导航、调试模式开关、分享指引，并扩展详情页与分享步骤。

Contrast — too technical and verbose (DON'T do this):
  ❌ EN: Implemented retreatStep method with spring animation for decrementing current step
         index, added DebugFlags.gettingStartedGuide persistence via Debug menu, introduced
         notification center event-driven mechanism for cross-component guide state sync,
         and refactored TagManagementView Sheet presentation to fix SwiftUI nesting re-render
  ❌ ZH: 实现 retreatStep 方法配合弹簧动画递减当前步骤索引，在 DebugFlags 中新增
         gettingStartedGuide 配置项通过 Debug 菜单持久化控制，引入通知中心事件驱动机制
         跨组件同步引导状态，并重构 TagManagementView 的 Sheet 呈现逻辑
```

### Bullet writing rules

写法以主规范为准：[`docs/5-规范/Changelog-更新规范.md`](../../../docs/5-规范/Changelog-更新规范.md) 第 4 节（App 更新说明友好）。摘要：

- **短标题 + 冒号 + 说明**：中文用全角 `：`；英文用半角 `: `（冒号后必须有空格）。不要靠第一个逗号拆标题；新条目不要用 em dash。
- **不要**以 `Added` / `Improved` / `Fixed` 或「新增 / 优化 / 修复」开头——分区标题已表达类别。
- **One idea per bullet**：短、可扫读；不写实现细节、文件路径、测试过程。
- **User-facing language**：写用户能感知的结果，像 App Store What's New。
- **Every non-excluded commit must be accounted for**：分组后确认 Step 3a 通过的 commit 都落在某条里。

→ 推荐形态：

```
EN: Repository pinning in Manage: Pin / Unpin, most-recently-pinned ordering, and a card-corner indicator.
ZH: Manage 仓库置顶：支持 Pin / Unpin，按最近置顶优先排列，卡片左上角显示置顶标识。
```

Contrast — too technical and verbose (DON'T do this):
  ❌ EN: Implemented retreatStep method with spring animation for decrementing current step
         index, added DebugFlags.gettingStartedGuide persistence via Debug menu...
  ❌ ZH: 实现 retreatStep 方法配合弹簧动画递减当前步骤索引...


---

## Step 5: Format and Insert into Both Files

Insert the new version section after the opening paragraph (the description line under the title)
and before the first existing `## <version>` section.

### English format

```markdown
## <version>

### New

- Short title: User-facing detail covering related changes.
- Another short title: Another detail.

### Improvements

- Short title: What got better for the user.

### Fixes

- Short title: What was broken and now works.
```

### Chinese format

```markdown
## <version>

### 新增

- 短标题：用户能懂的说明，可涵盖一组相关变更。

### 优化

- 短标题：体验或性能上的改进。

### 修复

- 短标题：已修好的问题。
```

分区标题必须用上表词（`New` / `Improvements` / `Fixes` 与 `新增` / `优化` / `修复`），不要写成 `Improved`、`Changed`、`改进`、`Bug Fixes`。完整约束见主规范第 4 节。

### Rules
- Categories with no entries → omit the section entirely
- Blank line between sections and between bullets
- Bullets start with `- ` (dash + space)
- Bullets use `短标题：说明`（中文全角冒号）或 `Short title: detail`（英文冒号+空格）；不要句首分类动词、不要用 em dash
- The version link reference goes at the bottom of the file（starcat-pro 渠道若在用）

---

## Step 6: Add Version Link Reference

At the bottom of each file, insert BEFORE the previous version's link:

```markdown
[<version>]: https://github.com/starcat-app/starcat-pro/releases/tag/<version>
```

Maintain reverse chronological order (newest first).

---

## Step 7: Verify Before Writing

Before touching any file, present the complete proposed changelog to the user:

1. Show the version number
2. Show ALL bullets under each category (EN + ZH side by side)
3. Confirm the count: "Total N commits → M user-facing bullets (X New, Y Improved, Z Fixed), K excluded (docs/tooling/internal)"

**Do NOT write files until the user explicitly approves the proposed content.**

After writing, verify:
- Both files have identical bullet counts per category
- Version number matches across both files
- Format matches existing entries exactly
- Version link references are present and in correct order

---

## Step 8: Offer to Create Git Tag

After both changelog files have been written and verified, ask the user:

> "Changelog updated. Would you like me to create a git tag `v<version>` for this release?"

Use the exact version number from Step 0. Do NOT create the tag without explicit confirmation.

If the user says yes:

```bash
git tag -a v<version> -m "v<version>"
```

Verify the tag was created:

```bash
git tag -l "v<version>"
```

---

## Step 9: Offer to Run Release Script

After the tag is created (or skipped by user), ask:

> "Would you like me to run the Direct release script (`scripts/release-direct.sh`) to publish this version?"

**Do NOT run the script without explicit confirmation.**

If the user says yes, present the script's requirements and parameters for confirmation:

### Script: `scripts/release-direct.sh <version>`

**Prerequisites:**
- Must be on `main` branch (or set `STARCAT_RELEASE_SKIP_BRANCH_CHECK=1`)
- Must have clean working tree (or set `STARCAT_RELEASE_SKIP_DIRTY_CHECK=1`)
- Requires: `git`, `python3`, `rsync`, `ssh`, `curl`

**Key parameters to confirm with user:**

| Parameter | Purpose | Recommendation |
|-----------|---------|----------------|
| `STARCAT_NOTARIZE=1` | Enable notarization | Required for production release |
| `STARCAT_RELEASE_SKIP_TAG=1` | Skip tag creation | Set if tag was already created in Step 8 |
| `STARCAT_RELEASE_DRY_RUN=1` | Dry run (no actual changes) | Suggest for first run to verify |
| `STARCAT_RELEASE_HOST=<host>` | SSH host for upload | Default: `aliyun` |
| `STARCAT_RELEASE_SKIP_NGINX=1` | Skip nginx deploy | Optional |
| `STARCAT_RELEASE_SKIP_SITE=1` | Skip site deploy | Optional |

**Ask the user:**
1. Is this a production release? (Yes → `STARCAT_NOTARIZE=1`)
2. Run dry-run first to verify?
3. Confirm SSH host (default: `aliyun`)
4. Any steps to skip?

After confirming all parameters, construct and execute the command:

```bash
# Example — actual command depends on user's answers
STARCAT_NOTARIZE=1 STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh <version>
```

**Note**: This script pushes tags to `origin`, deploys nginx config and site pages, packages the DMG,
signs it for Sparkle, uploads all artifacts to the remote server, and verifies remote URLs.
It is a full production release pipeline — make sure the user understands the scope.

---

## Important Constraints

1. **User-facing only** — exclude internal docs, build tooling, test fixes, review reports,
   appcast updates, sync scripts, and developer-only changes. Test: "Would a user notice this?"
2. **Read ALL commits first, filter later** — don't skip at read time; filter based on content in Step 3a
3. **Merge aggressively** — one bullet covers a topic cluster, not one commit
4. **User perspective** — describe what changed for the user, not the code
5. **Don't fabricate** — only include changes actually present in the git log
6. **Don't duplicate** — don't repeat changes already listed in earlier versions
7. **Preserve history** — never modify existing version sections
8. **Bilingual 1:1** — every EN bullet must have a corresponding ZH bullet
9. **Ask first, write later** — always show the proposed content and get approval
