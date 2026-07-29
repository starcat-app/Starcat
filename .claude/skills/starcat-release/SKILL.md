---
name: starcat-release
description: Starcat macOS App 专用双渠道发版流程。用于用户要发布或排查 App Store archive、Direct 分发、DMG 打包、Sparkle appcast 生成或上传、starcat.ink 官网与 changelog 部署、notarization、公版 tag 处理，或询问 scripts/package-appstore.sh、scripts/release-direct.sh、scripts/package-direct.sh、legacy release-store.sh 应该如何选择和运行的场景。
---

# Starcat 发版

使用这个 skill 选择并执行正确的 Starcat 双渠道发版路径。正式入口是 App Store
archive 与 Direct 公开发布两条；不要把 legacy 内测 DMG 流程或通用 macOS 发版流程
当成本仓库的权威正式流程。

## 硬性规则

- 始终用中文回复，并遵守仓库 `AGENTS.md`：先给方案并征求 dong4j 明确确认，再修改文件或运行有副作用的发版命令。
- 除非用户在当前对话中明确说“开干 / 执行 / 发布 / GO / 动手”，否则不要运行真实发布、部署、上传、`git tag`、`git push`、`rsync`、`ssh`、notarization 或 appcast 写入命令。
- 排查时先使用只读命令：`git status`、`git tag`、`git ls-remote`、`--help`、读取文件，以及脚本 dry-run 模式。
- 不要为了发版手动修改 `project.yml` 里的版本号字段。Starcat 的版本来自 git tag 和构建脚本。
- Starcat 已发布正式版；修改发版代码时保留线上用户、已发布 tag 和历史产物，不覆盖或复用既有版本。代码层废弃路径仍应一次性收口，不堆叠永久双轨。
- 保留无关未提交文件。工作区不干净时，先判断这些改动是否与发版任务相关，再提出下一步。

## 入口选择

先判断用户要走哪条路径：

| 用户意图 | 使用入口 | 原因 |
|---|---|---|
| App Store 发布准备、archive、Validate、上传 App Store Connect | `scripts/package-appstore.sh` / `make package-appstore` | 构建并校验 `Starcat` archive；上传继续由 Xcode Organizer / Transporter 完成 |
| Direct 公开发布、Sparkle 更新、starcat.ink 部署、上传 DMG/appcast | `scripts/release-direct.sh <X.Y.Z>` | Direct 渠道完整编排入口；发布后还要同步 Homebrew Cask |
| 只在本地构建 Direct 包 | `scripts/package-direct.sh <X.Y.Z>` | 构建 `StarcatDirect` DMG，可选 notarization/appcast |
| 历史 ad-hoc 内测 tag + DMG 流程 | `scripts/release-store.sh vX.Y.Z` | legacy 入口；默认禁用，必须显式设置 `STARCAT_ALLOW_LEGACY_RELEASE=1` |

如果用户只说“发版”但没有说明渠道，先确认是 App Store、Direct，还是双渠道。
如果用户提到 `starcat.ink`、Sparkle、appcast、notarization 或上传 DMG，可以推断为
Direct；提到 App Store Connect、Organizer、TestFlight 或审核则走 App Store。
两条路径都仍需先给方案并确认再执行。

## 标准工作流

1. 需要细节时先读 `references/release-map.md`。
2. 用只读命令检查当前状态：
   - `git status --short`
   - `git branch --show-current`
   - `git tag --sort=-creatordate | head`
   - Direct 发版可补充：`scripts/release-direct.sh --help`
3. 说明选择的入口、前提假设、副作用和验证标准。
4. 除非用户当前轮已经明确授权执行，否则先等确认。
5. 真实发布前优先 dry-run：
   - Direct：`STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh <X.Y.Z>`
   - App Store 没有发布 dry-run；先完成只读门禁，获授权后运行
     `make package-appstore`，该命令只生成 archive、不上传
6. 执行已确认的命令后，验证产物和 URL，并报告精确路径。

## App Store 发布

App Store archive 使用 `scripts/package-appstore.sh`，日常入口：

```bash
make package-appstore
make open-appstore-archive
```

`make package-appstore` 只生成并验证 archive，不上传。后续由 Xcode Organizer 执行
Validate App 与 Distribute App；不能把“archive 已生成”报告为“App Store 已发布”。

验证至少包括：

- archive 存在：`dist/appstore/Starcat-AppStore.xcarchive`；
- Bundle ID 为 `com.starcat.app.store`；
- `STARCAT_DISTRIBUTION=appstore`；
- 包含 App Sandbox entitlement；
- 不包含 `Sparkle.framework`；
- `codebase.bin`、主 App 与 dSYM UUID 检查通过。

## Direct 公开发布

Direct 分发使用 `scripts/release-direct.sh <X.Y.Z>`。它会执行：

1. 分支和干净工作区检查；
2. 创建并推送 tag；
3. 部署 nginx 配置；
4. 生成官网 changelog 并部署静态页面；
5. 带 `STARCAT_GENERATE_APPCAST=1` 调用 `package-direct.sh`；
6. 上传 DMG/SHA；
7. 合并并上传 appcast；
8. 校验线上 URL。

正式公开发布命令：

```bash
STARCAT_NOTARIZE=1 ./scripts/release-direct.sh X.Y.Z
```

演练命令：

```bash
STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh X.Y.Z
```

tag 已存在时重跑：

```bash
STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh X.Y.Z
```

只重跑 Direct 更新文件发布：

```bash
STARCAT_RELEASE_SKIP_TAG=1 \
STARCAT_RELEASE_SKIP_NGINX=1 \
STARCAT_RELEASE_SKIP_SITE=1 \
./scripts/release-direct.sh X.Y.Z
```

### 同步 Homebrew Cask

Direct 正式发布成功后，继续处理独立仓库
`supports/homebrew-starcat/Casks/starcat.rb`：

1. 从 `dist/direct/downloads/Starcat-<version>-arm64.dmg.sha256` 读取 SHA256，
   并对正式 DMG 实际计算一次 SHA256；两者必须一致。
2. 更新 Cask 的 `version` 和 `sha256`，URL 继续使用版本化
   `Starcat-#{version}-arm64.dmg`。
3. 在 `supports/homebrew-starcat` 独立仓库运行：

```bash
brew style Casks/starcat.rb
ruby -c Casks/starcat.rb
git diff --check
```

4. 正式发版授权包含 Homebrew 更新时，单独提交并推送该仓库的 `main`，等待
   `Audit Cask` Action 成功。
5. 从 `origin/main` 复核 Cask，而不是读取可能停留在 `dev` 的本地工作树。

Release、DMG、appcast 成功但 Cask 未更新或 `Audit Cask` 失败时，Direct 正式发布
仍视为未完成。不要覆盖旧 tag 或替换旧 Release 资产，应修复后发布新的 patch
版本，或在相同 App 版本仅修复 tap 时单独提交 Cask。

## Legacy 内测发版

`scripts/release-store.sh` 是历史 ad-hoc tag + DMG + push 流程，当前默认禁用，不是
App Store 或 Direct 的正式发布入口。只有用户明确要求复现旧内测流程时才可使用：

```bash
STARCAT_ALLOW_LEGACY_RELEASE=1 ./scripts/release-store.sh vX.Y.Z --dry-run
STARCAT_ALLOW_LEGACY_RELEASE=1 ./scripts/release-store.sh vX.Y.Z
```

本地试跑用 `--skip-push`。只有用户明确要 tag-only 行为时才使用 `--skip-dmg`。
不要为了绕过正式双渠道门禁而启用 legacy 入口。

## 验证标准

Direct 发布后验证：

- 本地 DMG 存在：`dist/direct/downloads/Starcat-<version>-arm64.dmg`；
- SHA 文件存在于 DMG 同目录；
- 当前版本 appcast 存在：`dist/direct/downloads/appcast-current.xml`；
- 合并后的 appcast 存在：`supports/starcat-site/direct/appcast.xml`，且引用新 DMG 和新版本号；
- 线上 URL 可访问：
  - `https://starcat.ink/appcast.xml`
  - `https://starcat.ink/downloads/Starcat-<version>-arm64.dmg`
  - `https://starcat.ink/changelog.html`
- `supports/homebrew-starcat` 的 `origin/main` 已声明相同版本和 DMG SHA256；
- `homebrew-starcat` 的 `Audit Cask` Action 成功。

legacy 内测发版后验证：

- DMG 存在：`build/dmg/Starcat-<version>-arm64.dmg`；
- SHA 文件存在于 DMG 同目录；
- 本地或远端 tag 状态符合用户确认的参数。

## 修改发版文档或脚本时

- 先检查 `docs/功能实现总览.md`、`docs/6-发版与上架/SOP-发版流程.md` 和相关脚本。
- 保持修改范围窄；只有行为契约变化时才同步更新文档。
- 如需更新进度文档，遵守 `AGENTS.md` 的 checkbox 和 `> 实现:` 规则。
- 修改 shell 脚本后用 `bash -n <script>` 验证语法。
- 修改 Python 脚本后用 `python3 -m py_compile <script>` 验证语法。

## 参考资料

读取 `references/release-map.md` 可查看脚本职责、环境变量、失败恢复方式和已知文档漂移点。
