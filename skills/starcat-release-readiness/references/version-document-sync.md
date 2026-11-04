# Starcat 版本文档同步

只在发布后版本文档审计或收口时读取。目标是让“当前公开版本”落点与已验证的公开事实一致，同时保留下一待发布版本和历史版本的正确语义。

## 1. 三个版本状态

- `PUBLISHED_VERSION`：已经由公开 tag、Direct appcast / DMG、GitHub Release、Homebrew，以及适用时的 App Store Connect 构建证明的当前公开版本。
- `PREVIOUS_VERSION`：发布前的上一个公开版本，用于定向搜索仍被描述成“当前 / 最新”的 stale candidate。
- `NEXT_PENDING_VERSION`：四份 Markdown Changelog 顶部的下一待发布版本。它可以高于 `PUBLISHED_VERSION`，但不能提前进入当前下载链接、Issue placeholder 或官网 Latest version。

`project.yml` 的 `MARKETING_VERSION` 是构建兜底，不是公开版本真值。历史 tag、迁移 identifier、兼容说明和测试夹具也不是“当前版本”来源。

## 2. 生成源与派生文件

先修改生成源，再生成派生文件，并分别审查每个独立仓库的 diff。

### 2.1 主仓库手工维护

- `README.md` / `README-ZH.md`：当前公开版本、Direct 下载 URL 和当前能力摘要。
- `.github/ISSUE_TEMPLATE/*.yml`：要求用户填写 Starcat 版本时的示例 placeholder。
- `supports/starcat-site/appstore/CHANGELOG.md` / `CHANGELOG-ZH.md`：App Store 当前正式版本与下一待发布区（2026-11 迁入，Starcat#202）。
- `supports/starcat-site/direct/CHANGELOG.md` / `CHANGELOG-ZH.md`：Direct 当前正式版本与下一待发布区。

`docs/功能实现总览.md` 受独立授权保护，不因本清单自动修改。

### 2.2 推广 README 生成链

- 生成源：`supports/scripts/sync-starcat-readme-promo.py`。
- 派生文件：脚本 `PROJECTS` 中每个独立仓库的 `README.md` / `README-ZH.md` marker 区块。
- 专用维护：`supports/starcat-site`（本身是生成目标，含双渠道 Changelog）与 `supports/.github/profile` 不适合机械重刷，必须单独检查。

更新生成源中的公开版本、下载 URL 和能力摘要后，才运行：

```bash
supports/scripts/sync-starcat-readme-promo.py
```

运行前后逐仓库记录状态。脚本只能改变 `starcat-promo` marker 管理的区域；出现 marker 外 diff 时停止。

### 2.3 用户文档与网站

- `supports/starcat-docs/changelog.mdx` 与 `zh-Hans/changelog.mdx`：面向用户的正式版本摘要，不复制完整 Changelog。
- `supports/starcat-site/direct/index.html` / `index-zh.html`：正式 Direct 页面中的 Latest version、下载 URL 和 fallback 元数据。
- `supports/starcat-site/direct-test/index.html` / `index-zh.html`：测试站对应 fallback。
- `supports/starcat-site/direct/changelog.html` / `changelog-zh.html`：只由正式 Changelog 生成器生成，不手改。

网站 fallback 的 version、build、URL 和 size 必须来自已发布 appcast / DMG 事实，不能凭预计产物填写。文件更新不授权部署。

### 2.4 发布事实交叉检查

- `supports/starcat-site/direct/appcast.xml`：版本、build、enclosure URL、length 与签名。
- `supports/homebrew-starcat/Casks/starcat.rb`：version、SHA256 和公开 DMG URL。
- GitHub Release：tag、标题、DMG 和 SHA256 资产。
- App Store：适用时分别记录上传、processing 和 review 状态；不能用 Direct 版本代替 App Store 状态。

## 3. 动态发现而非全局替换

Starcat 根目录包含多个独立 Git 仓库。先运行 skill 内 `scripts/audit-version-docs.sh`，再结合 `rg` 检查：

- `current version`、`current public version`、`current Direct build`、`latest version`。
- `当前版本`、`当前公开版本`、`当前 Direct 版本`、`最新版`。
- `Starcat-<version>-arm64.dmg`、Issue placeholder、网站 fallback 和版本徽章链接。

只把旧版本仍承担上述“当前语义”的行列为 stale candidate。以下位置默认保留：

- 历史 Changelog 和版本发布摘要。
- 数据库 migration identifier 与迁移边界注释。
- 旧版本升级、兼容性或故障复现说明。
- 测试夹具、示例命令和历史结果报告。
- 仍需支持的旧版下载或校验逻辑。

无法判断时只报告候选文件和行号，等待确认；禁止对整个 Starcat 目录执行版本号全局替换。

## 4. 验证与完成标准

1. 只读审计中 `PREVIOUS_VERSION` 的 stale candidate 为 0。
2. `PUBLISHED_VERSION` 在 appcast、Homebrew、根 README、官网 fallback、Issue placeholder 和推广生成源中一致。
3. `NEXT_PENDING_VERSION` 只出现在待发布 Changelog 和明确的开发计划语境，不冒充当前公开版本。
4. 推广生成脚本再次执行不产生额外 diff。
5. 每个改变的独立仓库分别通过 `git diff --check`；未提交、未 push 和非目标分支状态明确报告。
6. 中英文版本、下载链接和能力摘要语义对齐。
7. 线上页面只有在部署并重新获取验证后才记为 `PASS`；本地 HTML 正确仍只是本地文件证据。

最终报告分开列出：源文件、派生 README、用户文档、正式 Changelog HTML、官网 fallback、发布事实、Git 提交 / push、官网部署与公网验证。
