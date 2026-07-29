# Starcat 发版脚本地图

处理 Starcat 发版任务时使用这份参考。它记录当前仓库内各发版脚本的职责、环境变量和失败恢复方式。

## 脚本职责

| 文件 | 职责 | 备注 |
|---|---|---|
| `scripts/package-appstore.sh` | App Store archive 构建入口 | 构建并验证 `Starcat` archive；上传由 Xcode Organizer / Transporter 完成 |
| `scripts/release-direct.sh` | Direct 公开发布编排入口 | 完整路径：tag、官网/nginx 部署、Direct DMG、Sparkle appcast、上传、线上校验 |
| `scripts/release-store.sh` | 历史 ad-hoc 内测发版入口 | legacy 且默认禁用；需 `STARCAT_ALLOW_LEGACY_RELEASE=1`，不用于正式双渠道发布 |
| `scripts/package-direct.sh` | Direct 包构建入口 | 构建 `StarcatDirect`，校验 Sparkle 与非沙箱 entitlement，生成 DMG/SHA，可选 notarization/appcast |
| `scripts/build-dmg.sh` | legacy 内测 DMG 构建入口 | 仅供 `release-store.sh` 历史流程使用，输出到 `build/dmg/` |
| `scripts/merge-appcast.py` | appcast 合并工具 | 把当前版本 appcast item 合并进 `supports/starcat-site/direct/appcast.xml` |
| `supports/starcat-site/direct/deploy.sh` | 官网/nginx 部署脚本 | 一次完成 nginx 校验/reload 与静态官网同步 |
| `supports/starcat-site/direct/generate-changelog.py` | 官网 changelog 生成脚本 | 官网部署前生成 `supports/starcat-site/direct/changelog.html` |
| `docs/6-发版与上架/SOP-双渠道签名与发布.md` | 正式双渠道 SOP | App Store 与 Direct 的当前权威发布文档 |
| `docs/6-发版与上架/SOP-发版流程.md` | 较早的 legacy SOP | 只用于理解 tag / 版本号历史，不作为正式入口 |

## App Store archive 契约

`scripts/package-appstore.sh` 构建 `Starcat` scheme，并输出：

```text
dist/appstore/Starcat-AppStore.xcarchive
```

它会校验：

- `STARCAT_DISTRIBUTION=appstore`；
- Bundle ID 为 `com.starcat.app.store`；
- App Store 包包含 sandbox entitlement；
- App Store 包不包含 `Sparkle.framework`；
- 主 App、内置 `codebase.bin` 的签名与 dSYM UUID 一致性。

日常命令：

```bash
make package-appstore
make open-appstore-archive
```

`make package-appstore` 只生成 archive；Validate、Distribute 和 App Store Connect
processing 仍由 Xcode Organizer / Transporter 完成。

## Direct 发版契约

`scripts/release-direct.sh <X.Y.Z>` 接收纯数字版本号，例如 `1.1.0`，内部会构造 tag `v<X.Y.Z>`。

默认行为：

1. 要求当前分支等于 `STARCAT_RELEASE_BRANCH`，默认 `main`；
2. 要求工作区干净；
3. 除非设置 `STARCAT_RELEASE_SKIP_FETCH=1`，否则先同步远端 tags；
4. 创建 annotated tag `v<version>`；
5. 推送 tag 到 `STARCAT_RELEASE_REMOTE`，默认 `origin`；
6. 使用 `supports/starcat-site/direct/generate-changelog.py` 生成 changelog；
7. 使用 `supports/starcat-site/direct/deploy.sh` 部署 nginx 配置与静态官网；
8. 带 `STARCAT_GENERATE_APPCAST=1` 调用 `package-direct.sh`；
9. 验证本地 DMG/SHA/appcast-current 文件；
10. 使用 `rsync` 上传 DMG/SHA；
11. 合并并上传 `supports/starcat-site/direct/appcast.xml`；
12. 使用 `curl -fsSI` 校验线上 appcast、DMG 和 changelog URL；
13. 用正式 DMG 的 SHA256 更新 `supports/homebrew-starcat/Casks/starcat.rb`；
14. 单独提交并推送 Homebrew tap，等待 `Audit Cask` Action 成功。

重要环境变量：

| 变量 | 含义 |
|---|---|
| `STARCAT_NOTARIZE=1` | 在 `package-direct.sh` 内启用 notarization；公开发布建议开启 |
| `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD` | 开启 notarization 时必需 |
| `STARCAT_RELEASE_HOST` | SSH host，默认 `aliyun2` |
| `STARCAT_RELEASE_WEB_DIR` | 远程网站根目录，默认 `/var/www/starcat` |
| `STARCAT_SITE_ROOT` | 独立官网仓库路径，默认 `supports/starcat-site` |
| `STARCAT_DOWNLOAD_BASE_URL` | DMG URL 前缀，默认 `https://starcat.ink/downloads/` |
| `STARCAT_RELEASE_SKIP_TAG=1` | tag 已存在时重跑发布 |
| `STARCAT_RELEASE_SKIP_NGINX=1` | 跳过 nginx 部署 |
| `STARCAT_RELEASE_SKIP_SITE=1` | 跳过 changelog 和静态官网部署 |
| `STARCAT_RELEASE_DRY_RUN=1` | 打印副作用命令，并跳过状态写入、部署、构建、上传和线上校验 |

## Homebrew Cask 发布契约

`supports/homebrew-starcat` 是独立 Git 仓库。Direct 正式发布的最后阶段必须使
`Casks/starcat.rb` 与线上 DMG 保持一致：

```ruby
version "<X.Y.Z>"
sha256 "<Starcat-X.Y.Z-arm64.dmg 的真实 SHA256>"
```

更新前同时核对：

- `dist/direct/downloads/Starcat-<version>-arm64.dmg.sha256`；
- 对完整 DMG 实际运行 `shasum -a 256` 的结果；
- `https://starcat.ink/appcast.xml` 的 `sparkle:shortVersionString` 和 enclosure URL。

更新后运行 `brew style Casks/starcat.rb`、`ruby -c Casks/starcat.rb` 和
`git diff --check`。推送 tap 的 `main` 后等待 `Audit Cask`，并从
`origin/main:Casks/starcat.rb` 复核最终版本和 SHA256。本地 Homebrew 安装目录
可能仍缓存旧 tap，不能替代远端 `main` 验证。

## Legacy 内测发版契约

`scripts/release-store.sh` 接收 `vX.Y.Z` 或 `X.Y.Z`，归一化为 tag `vX.Y.Z`，并
调用 `scripts/build-dmg.sh X.Y.Z`。该入口默认拒绝执行，必须显式设置：

```bash
STARCAT_ALLOW_LEGACY_RELEASE=1
```

默认行为：

1. 检查 `STARCAT_ALLOW_LEGACY_RELEASE=1`；
2. 要求处于 git 仓库且工作区干净；
3. 确认本地和远端 tag 都不存在；
4. 展示摘要，除非 `--yes` 或 `--dry-run`，否则等待交互确认；
5. 创建本地 annotated tag；
6. 通过 `build-dmg.sh` 构建内测 DMG；
7. 除非 `--skip-push`，否则 push tag 到 origin；
8. 打印产物路径和 GitHub Release 创建链接。

仅当用户明确要求复现历史 ad-hoc 内测流程时使用。不要把它用于 App Store 或
Direct 正式发布，也不要用它绕过双渠道签名、公证、上传和审核门禁。

## Direct 包构建契约

`scripts/package-direct.sh <X.Y.Z>` 构建 `StarcatDirect` scheme。

它会校验：

- `xcodegen`、`xcodebuild` 和所选 DMG 工具存在；
- App bundle 内包含 `Sparkle.framework`；
- Info.plist 里的 `STARCAT_DISTRIBUTION` 为 `direct`；
- `CFBundleShortVersionString` 等于请求版本；
- `CFBundleVersion` 等于 `STARCAT_DIRECT_BUILD_NUMBER`，未设置时使用时间戳默认值；
- Direct 包不包含 `com.apple.security.app-sandbox`。

它会输出：

- `dist/direct/downloads/Starcat-<version>-arm64.dmg`；
- `dist/direct/downloads/Starcat-<version>-arm64.dmg.sha256`；
- 设置 `STARCAT_GENERATE_APPCAST=1` 时额外输出 `dist/direct/downloads/appcast-current.xml`。

## 失败恢复

| 失败点 | 建议处理 |
|---|---|
| 工作区不干净 | 停止；展示 `git status --short`；请用户决定 commit、stash 或确认范围 |
| App Store archive 生成失败 | 停止；检查 `dist/appstore/xcodebuild-appstore.log`、Apple Distribution identity 与 App Store target 配置 |
| Direct 分支不对 | 停止；询问是否切到 main，或是否仅为诊断显式跳过分支检查 |
| 本地 tag 已存在 | Direct 重跑使用 `STARCAT_RELEASE_SKIP_TAG=1`；legacy 流程则判断是否需要删除本地 tag |
| 远端 tag 已存在 | 不要自动删除；删除远端 tag 会影响协作者，必须让用户明确决定 |
| legacy 流程在本地 tag 后构建失败 | 默认保留 tag；如果用户想干净重试，再建议 `git tag -d vX.Y.Z` |
| Direct 包缺少 Sparkle | 视为构建/渠道配置问题；先检查 `project.yml` 和 target 设置，再重试 |
| Direct 包带 sandbox entitlement | 停止；Direct 必须非沙箱；检查 target entitlements 和 scheme |
| notarization 失败 | 检查 notarytool 输出和 Apple 凭证；除非用户明确选择，否则不要上传未 notarize 的公开 DMG |
| appcast 合并后缺少新 DMG/版本 | 停止；检查 `appcast-current.xml`、`supports/starcat-site/direct/appcast.xml` 和 `merge-appcast.py` |
| 线上 URL 校验失败 | 停止；检查上传路径、nginx/site 部署、DNS/TLS 和远程文件权限 |
| Homebrew Cask 仍是旧版本 | 从正式 DMG/SHA 文件更新 tap；不要只依赖 appcast 的 livecheck |
| `Audit Cask` 失败 | 停止；修复 Formula/Cask 语法、URL 或 SHA256，不能把 Direct 发布报告为完整成功 |

## 已知漂移

`docs/6-发版与上架/SOP-发版流程.md` 是较早的 tag + ad-hoc DMG 说明，仍围绕
legacy `release-store.sh`。正式发布以 `SOP-双渠道签名与发布.md` 为准：
App Store 使用 `package-appstore.sh`，Direct 使用 `release-direct.sh`。

根目录 `Makefile` 已提供 `package-appstore`、`open-appstore-archive`、
`package-direct`、`package-direct-notarized`、`release-direct`、
`release-direct-retry` 和 `release-direct-unnotarized`。`release-store` /
`release-dry-run` 仍指向 legacy `release-store.sh`，默认会被脚本自身的
`STARCAT_ALLOW_LEGACY_RELEASE=1` 门禁拒绝。
