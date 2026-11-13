---
name: starcat-release
description: Starcat macOS App 的 App Store、Direct 正式版和 Beta 发布、已有 DMG 续传及故障恢复。用于签名公证、GitHub Release、Sparkle 更新源、双语更新说明、官网部署和发布入口选择；支持只恢复已有产物而不重新构建。
---

# Starcat 发版

选择 App Store archive、Direct 正式版或 Direct Beta，并先判断是新构建还是已有产物恢复。
不要把 legacy 内测 DMG 流程当成本仓库的当前发布流程。

## 硬性规则

- 始终用中文回复，并遵守仓库 `AGENTS.md`：先给方案并征求 dong4j 明确确认，再修改文件或运行有副作用的发版命令。
- 修改脚本或 skill 的“开干 / 改吧”只授权约定的修改与测试，不自动授权真实发布。用户已明确授权当前任务的版本、渠道和发布范围后，同范围的故障恢复与收尾沿用该授权；不要因跨轮继续或可恢复失败反复征求许可。新版本、新渠道或范围外动作仍需授权；更高优先级规则要求暂停时说明具体来源。
- 排查时先使用只读命令：`git status`、`git tag`、`git ls-remote`、`--help`、读取文件，以及脚本 dry-run 模式。
- 不要为了发版手动修改 `project.yml` 里的版本号字段。Starcat 的版本来自 git tag 和构建脚本。
- Starcat 已发布正式版；保留线上用户、已发布 tag 和历史附件。同版本恢复只复用内容完全一致的原产物，不覆盖附件或改写 tag。
- 新构建要求对应发布分支和干净源码；只上传已公证产物使用 `--resume`，以原 tag、DMG 摘要和 appcast 为校验边界。保留并行改动，不为上传而自动 commit、stash、清理或新建 worktree。

## 入口选择

先判断用户要走哪条路径：

| 用户意图 | 使用入口 | 原因 |
|---|---|---|
| App Store 发布准备、archive、Validate、上传 App Store Connect | `scripts/package-appstore.sh` / `make package-appstore` | 构建并校验 `Starcat` archive；上传继续由 Xcode Organizer / Transporter 完成 |
| Direct 公开发布、Sparkle 更新、starcat.ink 部署、上传 DMG/appcast | `scripts/release-direct.sh <X.Y.Z>` | Direct 渠道完整编排入口；发布后还要同步 Homebrew Cask |
| Direct Beta / 预发布 | `scripts/release-direct-development.sh <X.Y.Z-beta.N>` | `dev` 分支新构建；GitHub prerelease、Beta feed 和官网双语更新日志 |
| 已有最终 DMG，上传或更新源中断 | 对应 Direct 脚本追加 `--resume` | 不构建、不改 tag；校验原产物后补 GitHub 附件和更新源，Beta 同时补发当次官网日志 |
| 已发布版本仅缺 appcast 双语说明 | 按 `references/release-map.md` 的“双语发布与更新说明修复”定向修复 | 使用当次快照补正文，核对原版本、下载与签名；不重打包或重发 Release |
| 只在本地构建 Direct 包 | `scripts/package-direct.sh <X.Y.Z>` | 构建 `StarcatDirect` DMG，可选 notarization/appcast |
| 历史 ad-hoc 内测 tag + DMG 流程 | `scripts/release-store.sh vX.Y.Z` | legacy 入口；默认禁用，必须显式设置 `STARCAT_ALLOW_LEGACY_RELEASE=1` |

如果用户只说“发版”但没有说明渠道，先确认是 App Store、Direct，还是双渠道。
如果用户提到 `starcat.ink`、Sparkle、appcast、notarization 或上传 DMG，可以推断为
Direct；提到 App Store Connect、Organizer、TestFlight 或审核则走 App Store。
先检查当前任务是否已有明确发布授权；有则继续执行约定范围。

## 标准工作流

1. 需要细节时先读 `references/release-map.md`。
2. 用只读命令检查当前状态：
   - `git status --short`
   - `git branch --show-current`
   - `git tag --sort=-creatordate | head`
   - Direct 发版可补充：`scripts/release-direct.sh --help`
3. 说明选择的入口、前提假设、副作用和验证标准。
4. 用户尚未授权该版本/渠道的真实发布时才等待确认；已授权任务的恢复直接继续。
5. 真实发布前优先 dry-run：
   - Direct：`STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh <X.Y.Z>`
   - App Store 没有发布 dry-run；先完成只读门禁，获授权后运行
     `make package-appstore`，该命令只生成 archive、不上传
6. 执行已确认的命令后，验证产物和 URL，并报告精确路径。
7. 发布收尾覆盖主仓库及 `supports/` 全部独立 Git 项目：同步、推送 `dev/main` 并回读远端 refs 验证一致；无远端项目核对本地两分支并明确报告。保留未发布的独立功能分支，按仓库分支规范登记结果。

### 更新窗口语言门禁

新构建保留 Sparkle 全部 `.lproj`，不得通过删除非英文资源固定更新窗口语言。
窗口文案跟随 `AppLocaleOverride`；下次打开窗口使用最新选择，已打开的 AppKit 控件不实时重建。
更新说明必须来自同次中英文发布快照：标准 `description` 同时包含 `xml:lang="en"` 与
`xml:lang="zh-Hans"`，并保留 `starcat:releaseNotes-en` 与 `starcat:releaseNotes-zh-Hans`
正文供客户端按应用语言读取；同一语言的标准说明与扩展字段正文必须一致。
只增加双语 description 仍不够，因为 Sparkle 默认按进程语言解析，不能替代客户端语言桥接。
简体中文、繁体中文共用中文日志，其余语言使用英文原文；跟随系统时按有效系统语言选择。
框架缺少的翻译回退英文。缺少任一种目标正文阻止生成，合并与普通续跑保留原说明，
不用当前工作稿覆盖快照或改写历史；已发布版本的说明修复按单独授权的元数据范围执行。

正式版和 Beta 均须分别核验官网中英文日志页与目标 appcast 的双语正文。发布完成前，
回读线上 feed 与本地候选逐字节比较，并解析确认本次条目的两种正文非空、字段完整。
官网中文页、窗口标题或按钮已中文、HTTP 200 均不能代替正文验收。修复后同步当次
`appcast-current.xml` 与官网仓库目标 feed，避免后续部署或续跑覆盖回旧说明。

涉及语言桥接或 appcast 生成的修改，运行 `scripts/tests/test_sparkle_localization.py`、
发布说明与恢复回归，并分别记录资源覆盖、无窗口模型验证、构建及人工 UI 验收结果。
需要调出窗口时，优先使用现有 `STARCAT_DIRECT_BUILD_NUMBER=1 make run-direct`，
不为绕过“已是最新版本”新增调试代码。快照路径、定向修复及人工验收见
[双语发布与更新说明修复](references/release-map.md#双语发布与更新说明修复)。

## 先判断状态，再选择恢复阶段

| 已核实状态 | 下一步 |
|---|---|
| 没有最终 DMG、SHA256 或当前 appcast | 处理构建/公证失败，不假装可续传 |
| 最终产物完整且已公证 | 对应脚本使用 `--resume`，不重打包或 staple |
| 草稿存在且缺附件 | 复用草稿，只上传缺失附件；已有附件下载核验 |
| Release 已公开且附件一致 | 只验证 GitHub，继续更新源；不重建 Release |
| GitHub 已公开、更新源已核验 | 核对官网双语日志正文；补齐原发布范围内的网页与渠道收尾后，提交元数据并同步各仓分支 |

GitHub 按 tag 查询返回 404 不能证明草稿不存在。上传器会分页查询草稿列表，
在首次判断和创建后回读都使用同一规则。出现重复草稿时，先核对 ID、归属和附件；
仅清理确认由本次任务误建的空草稿，不任意删除未知或有附件的 Release。

**重试边界**：发布器不自动重试写操作。超时或结果不明先回读实际状态；鉴权、重复草稿、
摘要冲突等逻辑错误不得靠重跑解决。同一错误再次出现时停止原命令的写操作，检查调用路径，
先用隔离测试复现并验证修复，再恢复。禁止“删除草稿 → 原样重跑”的循环，
也禁止调用真实发布函数来做探测性测试。

上传、下载核验和公开阶段必须立即输出进度与耗时。长阶段持续跟踪运行状态；
失败时说明具体阶段、已经完成的内容和下一步，不把“脚本在跑”当成进度。
网络读取只做有限重试，公开下载可用性可从本机验证，服务器出口故障不能直接推断附件缺失。

命令、校验与 Beta 完成标准见 [发布脚本地图](references/release-map.md)。

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
3. 带 `STARCAT_GENERATE_APPCAST=1` 调用 `package-direct.sh`，完成公证、staple、SHA256 和当前版本 appcast；
4. 校验本地产物并合并本地 appcast 历史版本；
5. 本机 `gh` 创建 GitHub Release 草稿，上传 DMG/SHA256，回读附件核验 SHA256 后公开；
6. 生成并部署官网 changelog、静态页和 nginx；
7. 确认 GitHub 下载可用后，仅向官网上传 appcast；
8. 校验官网 appcast、GitHub DMG 和 changelog。

DMG/SHA256 不再上传阿里云。appcast 继续由 `https://starcat.ink/appcast.xml` 提供，
官网和旧客户端共用该地址。生成清单无需等待附件上线，公开清单必须在附件验证之后。
GitHub 操作已由脚本调用 `publish-direct-github-release.py` 集成，不再安排发布后的第二次手工上传。

正式公开发布命令：

```bash
STARCAT_NOTARIZE=1 ./scripts/release-direct.sh X.Y.Z
```

演练命令：

```bash
STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh X.Y.Z
```

tag 已存在、尚需打包或续跑公证时：

```bash
STARCAT_NOTARIZE=1 STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh X.Y.Z
```

仅跳过 tag 不会跳过打包。最终产物已就绪时，使用下方 `--resume`。

### GitHub 上传失败后续跑

保留最终 DMG、SHA256 和 `appcast-current.xml`，使用：

```bash
./scripts/release-direct.sh X.Y.Z --resume
```

草稿只补缺失附件；已有附件必须下载核验与本地一致，不允许 `--clobber`。
已公开且一致的 Release 只验证；冲突或缺失附件时停止。此路径不重新打包或 staple，
也不发布当前工作区的官网静态页。原 `STARCAT_RELEASE_REUSE_ARTIFACTS=1` 使用相同恢复语义，
无需再组合跳过分支、脏状态或 tag 的开关。官网与 Homebrew 未完成时仍需按原范围收尾。

## Direct Beta

```bash
# 新构建；真实发布需已获授权。
STARCAT_NOTARIZE=1 ./scripts/release-direct-development.sh X.Y.Z-beta.N

# 最终 DMG 已有，恢复 GitHub prerelease、Beta 更新源和当次官网双语日志。
./scripts/release-direct-development.sh X.Y.Z-beta.N --resume
```

App 营销版本与附件名使用 `X.Y.Z`，tag 使用 `vX.Y.Z-beta.N`。
产物位于 `dist/direct-development/downloads/`；公布 `appcast-development.xml`，
并从 `release-notes-X.Y.Z-beta.N/` 固定快照生成、定向部署官网中英文更新日志。
两页均须显示本次 `X.Y.Z Beta N`，回读正文与本地逐字节一致，不含未来版本或待发布内容；
Release/feed 成功或网页 HTTP 200 不能代替此校验。正式 feed、官网默认稳定版下载、
Homebrew 和 App Store 保持原状。Beta 可复用对应版本待发布 Changelog。
原 `STARCAT_DEVELOPMENT_RELEASE_REUSE_ARTIFACTS=1` 同样进入产物恢复模式。

仅遗漏官网日志时，复用原说明快照，按 `starcat-public-site-and-promo` 的
`references/site-promo-map.md` 定向补发两页；无需重打包、重传 DMG 或全站部署。

## 同步正式版 Homebrew Cask

Direct 正式发布成功后，继续处理独立仓库
`supports/homebrew-starcat/Casks/starcat.rb`：

1. 从 `dist/direct/downloads/Starcat-<version>-arm64.dmg.sha256` 读取 SHA256，
   并对正式 DMG 实际计算一次 SHA256；两者必须一致。
2. 更新 Cask 的 `version` 和 `sha256`，URL 使用 GitHub Release 的版本化
   `https://github.com/starcat-app/Starcat/releases/download/v#{version}/Starcat-#{version}-arm64.dmg`。
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
- 本次条目满足“更新窗口语言门禁”，线上 feed 与本地发布内容逐字节一致，不能只查版本号或下载链接；
- 官网中英文日志页均来自当次双语快照，回读正文与本地生成结果逐字节一致；
- 线上 URL 可访问：
  - `https://starcat.ink/appcast.xml`
  - `https://github.com/starcat-app/Starcat/releases/download/v<version>/Starcat-<version>-arm64.dmg`
  - `https://starcat.ink/changelog.html`
  - `https://starcat.ink/changelog-zh.html`
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
