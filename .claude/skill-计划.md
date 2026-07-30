# Starcat Skill 沉淀计划

> 盘点日期：2026-07-07
> 范围：Starcat 仓库自有脚本，排除 `build/`、`dist/`、`.build/`、`node_modules/` 等构建产物和第三方依赖。
> 2026-07-29 更新：补齐正式版 Homebrew Cask 闭环，新增 CLI 联动发版与支撑项目创建 Skill。

## Skill 编写语言规范

本项目内新增或维护的所有 skill 必须使用中文编写，包括 `SKILL.md`、`references/` 下的说明文档、示例、触发说明和操作步骤。代码、命令、文件路径、环境变量、脚本名、错误日志、YAML key 等技术字面量保持原文，不强行翻译。

## 总体结论

当前最值得优先沉淀的是一个统一的 `starcat-release` skill，而不是把 `release-direct.sh` 和 `release.sh` 拆成两个互相独立的 skill。

原因：

- `scripts/release-direct.sh` 已经覆盖 Direct 公开发布的完整链路：git tag、官网部署、nginx reload、Direct DMG 打包、Sparkle appcast 上传、线上 URL 校验。
- `scripts/release.sh` 更像基础/内测发版入口：本地 tag、`build-dmg.sh`、push tag、GitHub Release 提示。
- `docs/6-发版与上架/SOP-发版流程.md` 仍把 `release.sh` 写成标准路径，但代码层面 `release-direct.sh` 已经承担 Direct 公开发布后半段。skill 必须明确两个入口的职责边界，避免后续 Agent 选错发布路径。

## P0：starcat-release

优先级：最高。

覆盖文件：

- `scripts/release-direct.sh`
- `scripts/release.sh`
- `scripts/package-direct.sh`
- `scripts/build-dmg.sh`
- `scripts/merge-appcast.py`
- `supports/starcat-site/direct/deploy.sh`
- `supports/starcat-site/direct/generate-changelog.py`
- `docs/6-发版与上架/SOP-发版流程.md`

建议触发场景：

- 用户说“发版”“发布 Direct 包”“发布官网更新”“生成 appcast”“打 tag 出 DMG”。
- 用户排查 Starcat 发布失败、Sparkle 更新失败、DMG 线上不可访问、appcast 不匹配。
- 用户问 `release-direct.sh` / `release.sh` / `package-direct.sh` 应该怎么用。

需要沉淀的关键规则：

- Direct 公开发布优先使用 `scripts/release-direct.sh <X.Y.Z>`。
- 基础/内测 DMG 或只想走 tag + DMG + push tag 时使用 `scripts/release.sh vX.Y.Z`。
- `release-direct.sh` 要求默认在 `main` 分支和干净工作区运行，除非明确用 `STARCAT_RELEASE_SKIP_*` 重跑部分阶段。
- `release.sh` 的核心顺序是先创建本地 tag，再 build DMG，最后 push tag；这样 build 失败时不会污染远端 tag。
- Direct 正式公开分发应设置 `STARCAT_NOTARIZE=1`，并准备 `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`。
- `package-direct.sh` 会验证 Direct 包必须包含 `Sparkle.framework`，且不能带 sandbox entitlement。
- Sparkle appcast 采用“当前版本生成 + 历史 appcast 增量合并”，历史版本以 `supports/starcat-site/direct/appcast.xml` 为准。
- 发布后必须校验 `https://starcat.ink/appcast.xml`、DMG 下载地址和 `https://starcat.ink/changelog.html`。

建议 skill 结构：

1. 入口选择：Direct 公开发布 vs 基础/内测发版。
2. 发布前检查：分支、dirty worktree、tag 冲突、Xcode、工具链、notarization 环境。
3. Direct 发布流程：tag -> nginx/site -> package-direct -> appcast merge -> upload -> remote verify。
4. 基础发版流程：local tag -> build-dmg -> push tag -> GitHub Release 提示。
5. 失败恢复：tag 已创建、build 失败、push 失败、appcast/DMG 上传失败、线上校验失败。
6. 禁止事项：不要手改 `project.yml` 版本号；不要把 `release.sh` 当成 Direct 全量发布；不要在正式发布时跳过 dirty check。

## P1：starcat-supports-ops

优先级：高。

覆盖文件：

- `supports/Makefile`
- `supports/start-all.sh`
- `supports/scripts/fly-secrets-sync.sh`
- `supports/scripts/fly-backup-data.sh`
- `supports/scripts/fly-restore-data.sh`
- `supports/scripts/warm-wiki-cache.sh`

建议触发场景：

- 用户说“启动后端服务”“同步 Fly secrets”“备份 Fly 数据”“恢复 Fly 数据”“预热 wiki 缓存”。
- 用户排查 supports 下多个 Go API 的本地联调或生产 Fly 状态。

沉淀价值：

- 这些脚本包含较多运维前置条件、服务端口、`.env` 到 Fly secrets 的映射、SQLite 持久化卷备份/恢复约束。
- 操作风险高，尤其是 restore / wipe / secrets，同步为 skill 可以减少手工误操作。

## P1：starcat-backend-release

优先级：高。

覆盖文件：

- `supports/starcat-sharing-api/scripts/deploy.sh`
- `supports/starcat-trending-api/scripts/deploy.sh`
- `supports/starcat-weekly-api/scripts/deploy.sh`
- `supports/starcat-wiki-api/scripts/deploy.sh`
- `supports/starcat-recommend-api/scripts/deploy.sh`
- `supports/starcat-discovery-api/scripts/deploy.sh`

建议触发场景：

- 用户说“发布后端 API”“给 supports 某个服务打 tag”“部署 Fly API”。
- 用户排查 GitHub Actions / Fly deploy 未触发或部署到错误 commit。

沉淀价值：

- 共享 deploy 流程包含 PR -> merge -> main pull -> tag -> GitHub Actions -> Fly deploy。
- 关键约束是 tag 必须指向 main 的 merge commit，不能指向 dev tip；不能在 main/master 上运行脚本。

## P1：starcat-cli-release

优先级：高。

覆盖文件：

- `supports/starcat-cli/.github/workflows/{ci,release}.yml`
- `supports/starcat-cli/scripts/{build-all,render-homebrew-formula}.sh`
- `supports/starcat-cli/CHANGELOG.md`
- `supports/starcat-cli/RELEASING.md`
- `supports/homebrew-starcat-cli/Formula/starcat.rb`
- `supports/homebrew-starcat-cli/.github/workflows/audit.yml`

建议触发场景：

- 用户说“发布 Starcat CLI”“给 CLI 升级版本”“验证 CLI Release”。
- 用户排查 CLI Release 成功但 Homebrew Formula 未更新或 Audit 失败。

沉淀价值：

- CLI 稳定版横跨两个独立仓库，完整状态是 Release、Formula 自动提交与 Audit Formula
  同时成功。
- checksums、attestations、五平台归档和版本注入需要按实际下载产物验证。

## P1：starcat-support-project-create

优先级：高。

覆盖文件：

- 支撑项目开源治理文件和双语 README；
- `supports/clone-all.sh`；
- `supports/scripts/sync-starcat-readme-promo.py`；
- `supports/{README,SYNC,AGENTS,CLAUDE}.md`；
- 按类型选择的 CI、Release、Dependabot、Fly.io 或商店发布文件。

建议触发场景：

- 用户说“在 supports 下创建新项目”“创建组织仓库并补齐开源文件”。
- 用户要求新项目加入 clone-all、README 营销同步和 supports 项目清单。

沉淀价值：

- 新项目不是单一目录创建，而是独立 Git 边界、开源治理、双语营销和中央登记的一致性
  事务。
- 使用拒绝覆盖的脚手架生成通用基线，项目类型差异继续由 Agent 按真实技术栈处理。

## P2：starcat-localization-sync

优先级：中。

覆盖文件：

- `supports/scripts/starcat-localization.py`
- `scripts/xcstrings_patch.py`
- `Starcat/Resources/Localizable.xcstrings`

建议触发场景：

- 用户说“导出本地化包”“导入 xcloc”“修 xcstrings”“同步翻译仓库”。

沉淀价值：

- `.xcstrings` 和 `.xcloc` 的方向容易弄反。
- Starcat 项目已有 i18n 规范，skill 可以把命令、路径、验证方式和禁止事项集中起来。

## P2：starcat-public-site-and-promo

优先级：中。

覆盖文件：

- `supports/starcat-site/direct/deploy.sh`
- `supports/starcat-site/direct/generate-changelog.py`
- `supports/scripts/sync-starcat-readme-promo.py`

建议触发场景：

- 用户说“部署官网”“生成 changelog 页面”“同步 README 推广区块”。

沉淀价值：

- 官网部署、nginx 部署、README 推广区块同步都涉及跨目录/跨项目内容一致性。
- 可以作为 `starcat-release` 的补充，也可以在后续拆成单独 skill。

## P3：暂不建议单独成 skill

这些脚本目前更适合作为其他 skill 的参考命令或附录，不建议第一阶段拆成独立 skill：

- `scripts/fetch-codebase-binary.sh`
- `scripts/generate_linguist_metadata.py`
- `scripts/generate-dmg-background.py`
- `scripts/sync-production-api-keys-from-env.sh`
- `scripts/run-debug-appstore.sh`
- `scripts/run-debug-direct.sh`
- `scripts/pr-helper.sh`
- 根目录 `Makefile`

理由：

- 使用频率或风险低于发版/运维脚本。
- 单独成 skill 会过早碎片化，后续 Agent 反而需要在多个 skill 间选择。
- 可以先作为 `starcat-release`、`starcat-supports-ops` 或未来 `starcat-dev-ops` 的附录沉淀。

## 推荐落地顺序

1. `starcat-release` 负责 App Store / Direct 正式版发布和 Homebrew Cask 闭环。
2. `starcat-cli-release` 负责 CLI Release 与 Homebrew Formula 闭环。
3. `starcat-support-project-create` 负责新支撑项目开源基线与中央登记。
4. `starcat-supports-ops` / `starcat-backend-release` 继续负责已有 API 的运维和发布。
5. `starcat-localization-sync` / `starcat-public-site-and-promo` 负责内容型跨仓库流程。

## starcat-release 已确认规则

- Direct 公开发布使用 `scripts/release-direct.sh <X.Y.Z>`。
- App Store archive 使用 `scripts/package-appstore.sh` / `make package-appstore`。
- legacy `release-store.sh` 默认禁用，不作为正式版入口。
- Direct 完成标准包含 `homebrew-starcat` Cask 同步和 `Audit Cask` 成功。
