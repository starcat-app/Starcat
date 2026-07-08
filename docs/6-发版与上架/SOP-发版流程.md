# 发版流程

> 创建：2026-06-07
> 适用范围：Starcat macOS App
> 配套实现：`scripts/bump-version.sh` + `project.yml` 中的 `postBuildScripts`

---

## TL;DR（一句话答案）

**版本号字段全自动**，发版一行命令：

```bash
./scripts/release-store.sh v0.1.1
```

它会按顺序：① 校验 working tree 干净 / tag 不冲突 → ② 二次确认 → ③ 本地打 tag → ④ 跑 `scripts/build-dmg.sh` 出 DMG（产物 plist 由 `bump-version.sh` 自动写入版本号）→ ⑤ push tag 到远端 → ⑥ 打印 GitHub Release 创建链接。

**如果只想自己控**，最低要求也只是：

```bash
git tag v0.1.1 && git push --tags
```

`CFBundleShortVersionString`（marketing 版本）和 `CFBundleVersion`（build 号）都不用手动改 `project.yml`，下次 `xcodebuild` 或 Xcode 跑一次，关于页 / Finder 简介 / DMG 包名版本就自动跟上。

---

## 1. 版本号机制（必读，理解后才能正确用）

### 1.1 关于页 UI 显示

```
Version 0.1.0 (Build 201.f09a499)
        ↑           ↑    ↑
        |           |    └── git 短 hash
        |           └────── git commit 总数
        └────────────────── git tag（去掉 v 前缀）
```

### 1.2 三段值的来源

| 字段 | 信息源 | 计算方式 |
|---|---|---|
| Marketing 版本 | git tag | `git describe --tags --abbrev=0` 去掉 `v` 前缀 |
| Build 号 | git commit 总数 | `git rev-list --count HEAD` |
| Commit hash | git HEAD | `git rev-parse --short=7 HEAD` |

### 1.3 写到 Info.plist 的字段

| Plist Key | 例值 | 谁写入 | App Store 规范 |
|---|---|---|---|
| `CFBundleShortVersionString` | `0.1.0` | 脚本（有 tag 才覆盖，无 tag 保留 `MARKETING_VERSION` 兜底） | 必须是 `x.y.z` SemVer |
| `CFBundleVersion` | `201` | 脚本（每次 build 必写，纯 commit count） | 必须是 period-separated 非负整数 |
| `GitCommitHash` | `f09a499` | 脚本（自定义 key，每次 build 必写） | App Review 不审自定义 key |

> 拆 commit count 与 hash 是为了一次性满足 App Store 规范（详见 `docs/功能实现总览.md` 2026-06-07 14:50 条）。

### 1.4 配套脚本何时跑

- 在 Xcode build phase 的 `postBuildScripts` 中执行（target 所有 phase 之后、codesign 之前）。
- `basedOnDependencyAnalysis: false` 强制每次 build 都跑，避免 Xcode incremental cache 跳过。
- 命令行 `./scripts/bump-version.sh` 也可以手动跑（无 plist 路径时只打印计算结果不写文件，用于排查）。

---

## 2. 标准发版 SOP（每次发版都按这个走）

### 推荐路径：`scripts/release-store.sh`（一键发版）

`release-store.sh` 是发版总入口，把"打 tag → 出 DMG → 推 tag"串起来，并做完整前置校验。

```bash
./scripts/release-store.sh v0.1.1                # 标准发版（happy path）
./scripts/release-store.sh v0.1.1 --dry-run      # 先演练看流程
./scripts/release-store.sh v0.1.1 --yes          # CI 友好，跳过二次确认
./scripts/release-store.sh v0.1.1 --skip-dmg     # 只打 tag + push，不出 DMG
./scripts/release-store.sh v0.1.1 --skip-push    # 只本地 tag + 出 DMG，不推远端
./scripts/release-store.sh --help                # 完整用法
```

执行顺序（**先本地 tag → build → push tag**，build 失败时 tag 还在本地不污染远端）：

1. **前置检查**：git 仓库 / working tree 干净 / tag 在本地与远端均未占用 / `build-dmg.sh` 可执行 / `origin` 远端配置 ✓
2. **摘要 + 二次确认**：列出目标 tag / 预期 marketing 版本 / 自动算出的 build 号 / 当前 commit / 是否 push
3. **Phase 1**：`git tag -a vX.Y.Z -m "Release vX.Y.Z"`（**仅本地**）
4. **Phase 2**：`scripts/build-dmg.sh X.Y.Z`（内部自动跑 `xcodegen` + `xcodebuild`，触发 `postBuildScripts` 中的 `bump-version.sh` 读取刚打的本地 tag 写 plist）
5. **Phase 3**：`git push origin vX.Y.Z`
6. **最终摘要**：DMG 路径 / SHA-256 / GitHub Release 创建链接

**自带防御**：
- 任何 phase 失败都会保留本地 tag 并提示如何处理（删 tag / 重试 push）
- `Ctrl+C` 中途打断走相同的 trap
- `v` 前缀可省可加，内部归一化（与 `build-dmg.sh` 严格 `X.Y.Z` 接口对齐）
- 严格 SemVer X.Y.Z 校验（暂不支持 `-beta` / `-rc` 后缀，与 `build-dmg.sh` 限制一致）

> 下面 §2.x 的 5 步 SOP 是脚本背后做的事，理解一下有助于排查问题，但日常用 `release-store.sh` 一行就够。

### 第 1 步：定 marketing 版本号（SemVer）

按 [SemVer](https://semver.org) 规则三选一：

| 改动类型 | 旧版本 | 新版本 | 例子 |
|---|---|---|---|
| **PATCH**（bug 修复 / 文档 / 小优化，无 API / UI 变化） | `0.1.0` | `0.1.1` | "修复 sidebar 数字溢出" |
| **MINOR**（新功能，向后兼容） | `0.1.0` | `0.2.0` | "新增 AI 摘要" |
| **MAJOR**（破坏性变更：DB 不兼容 / UI 大改 / 移除功能） | `0.9.0` | `1.0.0` | "1.0 正式版" |

> Starcat 当前还在 `0.x` 阶段，所有版本号都按 `0.x.y` 走；首个公开发布版本（无破坏性变更承诺）才升 `1.0.0`。

### 第 2 步：确认所有改动已 commit 干净

```bash
git status
# 必须是 working tree clean
git log --oneline -5
# 确认最新 commit 是这次发版要包含的
```

> 如果有未提交改动，build 出来的 hash 还是上一个 commit 的 hash，不能反映"真正 build 的代码"。

### 第 3 步：打 tag

格式必须是 `v` + SemVer：

```bash
git tag v0.1.1
```

> ⚠️ 必须以 `v` 开头。脚本里 `MARKETING="${TAG#v}"` 会去掉 `v` 前缀；如果你直接打 `0.1.1`，脚本也能识别，但项目约定**统一用 `v` 前缀**与 GitHub Release 习惯对齐。

### 第 4 步：推送 tag

```bash
git push --tags
```

> 单独 `git push` 不会推 tag，必须加 `--tags`。

### 第 5 步：build 一次验证

可选 ① Xcode IDE 里 Cmd+R 启动，打开关于页确认；或 ② 命令行：

```bash
xcodegen generate
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build
```

期望日志里看到：

```
==> Auto Bump Version
    git latest tag   : v0.1.1
    -> CFBundleVersion              = <commit_count>
    -> GitCommitHash                = <short_hash>
    -> CFBundleShortVersionString   = 0.1.1 (from tag)
```

---

## 3. 典型场景速查

> 全部场景都可以用 `release-store.sh` 一行搞定，下面命令保留两种写法（推荐路径 + 手动等价命令）方便对照理解。

### 3.1 首次发版（0.1.0 → 0.1.1，目前的 hot path）

```bash
# 推荐
./scripts/release-store.sh v0.1.1

# 手动等价
git tag v0.1.1 && git push --tags
./scripts/build-dmg.sh 0.1.1
```

### 3.2 hotfix（紧急修复线上 bug）

```bash
# 1. 切到对应 release 分支或主分支
git checkout main
# 2. 修复 bug 并 commit
git commit -m "fix: 紧急修复 X"
# 3. 一键发版
./scripts/release-store.sh v0.1.2
```

### 3.3 pre-release（beta / rc）

```bash
git tag v0.2.0-beta.1   # 或 v0.2.0-rc.1
git push --tags
```

> SemVer 规范支持 `-beta.1` / `-rc.1` 等后缀，`git describe --tags --abbrev=0` 能正确取到，UI 会显示成 `Version 0.2.0-beta.1 (Build 220.abc1234)`。

### 3.4 撤销错误的 tag

如果 tag 打错了（比如版本号写错），**还没 push** 就 `git tag -d`：

```bash
git tag -d v0.1.1
```

如果**已经 push** 了：

```bash
git tag -d v0.1.1                  # 删本地
git push origin :refs/tags/v0.1.1  # 删远端
# 再重新打正确的 tag
git tag v0.1.2
git push --tags
```

> 已 push 的 tag 删除会影响其他协作者，能避免就避免。版本号"打错了不如就那么发"，下个版本顺势 +1。

### 3.5 没打 tag 直接 build 会怎样

不会失败，但 marketing 版本会 fallback 到 `project.yml` 里 `MARKETING_VERSION: "0.1.0"`：

```
==> Auto Bump Version
    git latest tag   : <none>
    -> CFBundleShortVersionString   = (keep existing, no git tag yet)
```

UI 仍显示「Version 0.1.0 (Build 201.f09a499)」，build 号和 hash 仍正确反映当前代码，只是 marketing 版本"懒得跟"。

---

## 4. 完整发版核对清单（SOP 之外的扩展项）

发布前**最好**做完以下：

- [ ] **`docs/功能实现总览.md`** —— 顶部「最近更新」+「变更日志」追加发版条目（参考已有格式）
- [ ] **CHANGELOG**（可选）—— 当前还没建，等 1.0 之前可考虑
- [ ] **测试** —— `xcodebuild test` 全绿，至少跑一次冒烟测
- [ ] **手动验证** —— Xcode IDE Cmd+R 启动一次，关于页显示正确
- [ ] **打 tag** —— `git tag vX.Y.Z` + `git push --tags`
- [ ] **DMG 打包**（如发布到 Release）—— 跑 `scripts/build-dmg.sh 0.1.1`（**当前需手动传版本号**，详见 §5 Q8）
- [ ] **GitHub Release**（如对外公开）—— 在 GitHub 仓库 → Releases 页面，基于刚 push 的 tag 创建 Release，附 DMG 下载链接和发版说明

---

## 5. 常见误区 / FAQ

### Q1：我改了 `project.yml` 里的 `MARKETING_VERSION: "0.1.0"`，会生效吗？

**会，但只在没 tag 的情况下生效**。一旦你打了 tag，脚本会用 tag 值覆盖 `project.yml` 里的兜底值。所以**不要改 `project.yml` 的版本号字段**——保留它作为"完全没 tag 时的应急兜底"即可。

### Q2：我改了 commit 但没打 tag，关于页 build 号会变吗？

**会**。Build 号 = commit count，每多一个 commit 就 +1；hash 也会变。但 marketing 版本不会变。这是预期行为。

### Q3：脚本写的 plist 是源文件还是产物？

**只改产物**（即 `.app/Contents/Info.plist`）。源 `Info.generated.plist` 由 xcodegen 生成、Xcode 在 Process Info.plist phase 写入产物，**之后**才被脚本覆盖。每次 build 都会重新生成 + 重新覆盖，永远不会脏。

### Q4：CFBundleVersion 含字母 hash 不是 App Store 不允许吗？

**v2 已经修了**（2026-06-07 14:50）。现在 `CFBundleVersion = 201` 是纯整数符合规范；hash 走自定义 key `GitCommitHash`，App Review 不审自定义 key。UI 仍能显示完整 `201.f09a499`。

### Q5：CI 上 build 没 git history（shallow clone）怎么办？

`git rev-list --count HEAD` 会返回偏小的值（仍然是非负整数，不会让 build 失败）。如果 CI 严格要求版本号单调递增，在 CI 配置里加 `git fetch --unshallow` 或 clone 时用 `--depth=0`。GitHub Actions 默认 shallow clone，需要在 `actions/checkout@v4` 里设 `fetch-depth: 0` + `fetch-tags: true`。

### Q6：第一次发版还没 tag 想看版本号"假装是 0.1.1"怎么办？

**不要伪造**——直接在打 tag 之前显示 `0.1.0`（兜底值）即可。要 `0.1.1` 就先 `git tag v0.1.1 && git push --tags`，开发期想要哪个就打哪个 tag，反正 tag 想删能删。

### Q7：能不能让 build 号包含未 commit 的 dirty 标记？

可以（脚本里加 `git diff --quiet || BUILD="${BUILD}.dirty"`），但目前没加。如果 dong4j 后续要加，告诉我，5 行改动就能接入。

### Q8：`scripts/build-dmg.sh` 也是自动读 git tag 吗？

**目前不是**。`build-dmg.sh` 当前接收命令行参数：

```bash
./scripts/build-dmg.sh 0.1.1
```

它会通过 `xcodebuild MARKETING_VERSION=0.1.1 CURRENT_PROJECT_VERSION=<timestamp>` 覆盖 build settings，但因为我们的 `bump-version.sh` 在 `postBuildScripts` 里仍会用 git tag 覆盖产物 plist，**最终 .app 里的版本号是 git tag 值，不是你传给 build-dmg.sh 的值**。这两个会"打架"。

**当前推荐用法**：保持 git tag 与 build-dmg.sh 参数一致：

```bash
git tag v0.1.1 && git push --tags
./scripts/build-dmg.sh 0.1.1   # 与 tag 同版本号
```

**待办**：后续可让 `build-dmg.sh` 也优先读 git tag（自动 = `git describe --tags --abbrev=0 | sed 's/^v//'`，无 tag 才接受参数），但这不在本次范围。

---

## 6. 相关文件索引

| 角色 | 路径 |
|---|---|
| **发版总入口** | **`scripts/release-store.sh`（推荐用法）** |
| 版本写入脚本 | `scripts/bump-version.sh`（由 Xcode postBuildScripts 自动触发） |
| DMG 打包 | `scripts/build-dmg.sh`（接收 `$1` 参数；release-store.sh 会自动调它） |
| Build phase 配置 | `project.yml` → `targets.Starcat.postBuildScripts` |
| Info.plist 兜底值 | `project.yml` → `settings.base.MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |
| 关于页 UI 读取 | `Starcat/Features/About/AboutView.swift` → `AboutVersion.current` / `displayBuild` |
| 本地化字符串 | `Starcat/Resources/Localizable.xcstrings` → `about.version.fullFormat` |
| 实现历史 | `docs/功能实现总览.md` 变更日志 2026-06-07 14:35 / 14:50 / 15:00 / 15:10 四条 |

---

## 7. 一图流：发版决策树

```
今天要发版？
   │
   ├── 否 → 继续 commit 即可（build 号自动涨，marketing 保持上次 tag）
   │
   └── 是 → 先 commit 完所有改动 → 决定 SemVer 等级
                                    │
                                    ├── 修 bug          → vX.Y.(Z+1)
                                    ├── 加新功能(兼容)  → vX.(Y+1).0
                                    └── 破坏性变更      → v(X+1).0.0
                                                ↓
                                    ./scripts/release-store.sh vX.Y.Z
                                                ↓
                                    脚本完成：tag → DMG → push → 提示 Release 链接
                                                ↓
                                    （可选）打开提示链接，在 GitHub 创建 Release 公开
```

---

## 8. 封版后的 Bug 修复流程

> 创建：2026-06-28
> 适用场景：已通过 `release-store.sh` 打 tag 封版的版本（如 v1.0.0），发现代码 bug 需要修复。
> 核心原则：**封版 ≠ 不可改**。未公开前按 §8.1 走；公开后按 §8.2 走。

### 8.1 未上架场景（tag 可移动）

> **适用判定**：vX.Y.Z 尚未在 App Store / TestFlight 对外发布，**且**未在 GitHub 公开 Release / 未通过 DMG 公开发放下载。
> **本质**：tag 是「内部版本号」，未公开前可以原地「滑动」到修复后的 commit，不增加版本号。

```bash
# 0. 前提：main 当前 HEAD 在 vX.Y.Z tag 附近（或其后代）
git checkout main
git pull origin main
git log --oneline -1 vX.Y.Z   # 确认 tag 当前指向

# 1. 开修复分支（避免直接在 main 上 commit，便于回退）
git checkout -b fix/vX.Y.Z-<short-desc>

# 2. 修 + commit
git commit -m "fix(starcat): ..."

# 3. merge 回 main
git checkout main
git merge --ff-only fix/vX.Y.Z-<short-desc>

# 4. 移动 tag 到新 commit（不增版本号！）
git tag -d vX.Y.Z
git tag -a vX.Y.Z -m "Release vX.Y.Z — <新 commit 的修复说明>"
git push origin :refs/tags/vX.Y.Z
git push origin vX.Y.Z

# 5. 清理修复分支
git branch -d fix/vX.Y.Z-<short-desc>
```

**风险与约束**：
- 移动已 push 的 tag = force update，团队协作者需要 `git fetch --tags --force`
- 若在 GitHub 上基于该 tag 创建过 Release / 附件 / 链接，移动后这些会指向新 commit（内容不同）
- 因此**只在「未公开 Release + 未对外分发 DMG」时使用**

### 8.2 已上架场景（必须开 release 分支）

> **适用判定**：vX.Y.Z 已在 App Store / TestFlight 发布，或 DMG 公开下载链接已发出。
> **本质**：不能动 vX.Y.Z tag（已下载用户校验和会错乱）。开长期维护的 release 分支，hotfix 走新版本号。

```bash
# 1. 从 vX.Y.Z tag 开 release 分支（长期保留，与 main / dev 并行）
git checkout -b release/vX.Y.x vX.Y.Z
git push -u origin release/vX.Y.x

# 2. 修 + commit
git commit -m "fix(starcat): ..."

# 3. 打新版本 tag（递增 PATCH 位，X.Y.Z → X.Y.(Z+1)）
git tag -a vX.Y.(Z+1) -m "Hotfix vX.Y.(Z+1) — <修复说明>"
git push origin vX.Y.(Z+1)

# 4. cherry-pick 回 main，让 main 也包含这个修复
git checkout main
git cherry-pick <commit-hash>
git push origin main

# 5. dev 上的 v(X.Y+1).0 是否需要这个修复？
#    视情况：仅严重 bug 才 cherry-pick 到 dev，避免污染下一版开发线
git checkout dev
git cherry-pick <commit-hash>   # 或：git merge release/vX.Y.x

# 6. release/vX.Y.x 分支长期保留
```

**为什么必须开 release 分支**：
- 动 vX.Y.Z tag 会让已下载 vX.Y.Z 的用户校验和失败 / 自动更新错乱
- vX.Y.(Z+1) / vX.Y.(Z+2) 走 release 分支，避免污染 main 上下一版的开发
- cherry-pick 保证 main 不会「漏修」，下次封版时所有 hotfix 都已合入

### 8.3 决策树

```
发现 vX.Y.Z bug？
  │
  ├── vX.Y.Z 是否已对外发布（满足任一即视为已发布）？
  │     • App Store / TestFlight 已上架
  │     • GitHub Release 公开（带 DMG 附件）
  │     • DMG 公开发放下载链接
  │     │
  │     ├── 全部否 → §8.1 未上架：tag 移动（不开新版本号）
  │     │
  │     └── 任一为是 → §8.2 已上架：开 release/vX.Y.x → 修 → vX.Y.(Z+1) → cherry-pick 回 main
  │
  └── 修复后是否需要回 dev / main？
        │
        ├── §8.1：merge 回 main，main = vX.Y.Z 当前真值
        └── §8.2：cherry-pick 到 main；dev 分支的下一版是否需要？
              │
              ├── 严重 bug → 在 dev 上 cherry-pick（或 merge release 分支到 dev）
              └── 非严重   → 仅 main 持有修复，dev 下一版再统一处理
```

### 8.4 注意事项

- **`release-store.sh` 在 §8.1 流程中不要跑**——它会拒绝覆盖已存在的 tag。手动 git tag 即可。
- **§8.1 的 tag 移动会触发 `bump-version.sh` 的 plist 更新**——下次 build 的产物会自动反映新 commit 的 hash（build 号 = commit count，自动 +1）
- **cherry-pick 可能冲突**：release 分支的 commit 与 main / dev 后续演进可能重叠，冲突时人工解决
- **release 分支的命名严格 `release/vX.Y.x`**（X.Y 不变，x 留作未来命名扩展位），与 dev / main 长期并行

---

*最后更新：2026-06-28*
