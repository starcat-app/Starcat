# Starcat 发版脚本地图

处理 Starcat 发版任务时使用这份参考。它记录当前仓库内各发版脚本的职责、环境变量和失败恢复方式。

## 脚本职责

| 文件 | 职责 | 备注 |
|---|---|---|
| `scripts/release-direct.sh` | Direct 公开发布编排入口 | 完整路径：tag、官网/nginx 部署、Direct DMG、Sparkle appcast、上传、线上校验 |
| `scripts/release.sh` | 基础/内测发版编排入口 | 本地 tag -> `build-dmg.sh` -> push tag；不部署官网和 appcast |
| `scripts/package-direct.sh` | Direct 包构建入口 | 构建 `StarcatDirect`，校验 Sparkle 与非沙箱 entitlement，生成 DMG/SHA，可选 notarization/appcast |
| `scripts/build-dmg.sh` | 内测 DMG 构建入口 | 构建 `Starcat` ad-hoc/内部 DMG，输出到 `build/dmg/` |
| `scripts/merge-appcast.py` | appcast 合并工具 | 把当前版本 appcast item 合并进 `pages/appcast.xml` |
| `pages/deploy.sh` | 官网/nginx 部署脚本 | `-n` 部署 nginx 配置；无参数部署静态官网 |
| `pages/generate-changelog.py` | 官网 changelog 生成脚本 | 官网部署前生成 `pages/changelog.html` |
| `docs/6-发版与上架/SOP-发版流程.md` | 较早的发版 SOP | 当前主要强调 `release.sh`；更新 Direct 发版文档时要检查漂移 |

## Direct 发版契约

`scripts/release-direct.sh <X.Y.Z>` 接收纯数字版本号，例如 `1.1.0`，内部会构造 tag `v<X.Y.Z>`。

默认行为：

1. 要求当前分支等于 `STARCAT_RELEASE_BRANCH`，默认 `main`；
2. 要求工作区干净；
3. 除非设置 `STARCAT_RELEASE_SKIP_FETCH=1`，否则先同步远端 tags；
4. 创建 annotated tag `v<version>`；
5. 推送 tag 到 `STARCAT_RELEASE_REMOTE`，默认 `origin`；
6. 使用 `pages/deploy.sh -n` 部署 nginx 配置；
7. 使用 `pages/generate-changelog.py` 生成 changelog；
8. 使用 `pages/deploy.sh` 部署静态官网；
9. 带 `STARCAT_GENERATE_APPCAST=1` 调用 `package-direct.sh`；
10. 验证本地 DMG/SHA/appcast-current 文件；
11. 使用 `rsync` 上传 DMG/SHA；
12. 合并并上传 `pages/appcast.xml`；
13. 使用 `curl -fsSI` 校验线上 appcast、DMG 和 changelog URL。

重要环境变量：

| 变量 | 含义 |
|---|---|
| `STARCAT_NOTARIZE=1` | 在 `package-direct.sh` 内启用 notarization；公开发布建议开启 |
| `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD` | 开启 notarization 时必需 |
| `STARCAT_RELEASE_HOST` | SSH host，默认 `aliyun` |
| `STARCAT_RELEASE_WEB_DIR` | 远程网站根目录，默认 `/var/www/starcat` |
| `STARCAT_DOWNLOAD_BASE_URL` | DMG URL 前缀，默认 `https://starcat.ink/downloads/` |
| `STARCAT_RELEASE_SKIP_TAG=1` | tag 已存在时重跑发布 |
| `STARCAT_RELEASE_SKIP_NGINX=1` | 跳过 nginx 部署 |
| `STARCAT_RELEASE_SKIP_SITE=1` | 跳过 changelog 和静态官网部署 |
| `STARCAT_RELEASE_DRY_RUN=1` | 打印副作用命令，并跳过状态写入、部署、构建、上传和线上校验 |

## 基础发版契约

`scripts/release.sh` 接收 `vX.Y.Z` 或 `X.Y.Z`，归一化为 tag `vX.Y.Z`，并调用 `scripts/build-dmg.sh X.Y.Z`。

默认行为：

1. 要求处于 git 仓库且工作区干净；
2. 确认本地和远端 tag 都不存在；
3. 展示摘要，除非 `--yes` 或 `--dry-run`，否则等待交互确认；
4. 创建本地 annotated tag；
5. 通过 `build-dmg.sh` 构建内测 DMG；
6. 除非 `--skip-push`，否则 push tag 到 origin；
7. 打印产物路径和 GitHub Release 创建链接。

仅当用户需要本地/内测 DMG，或简单的 tag + DMG + push 流程时使用它。不要把它用于 Direct 公开发布，因为它不会部署官网、上传 DMG、合并 appcast 或校验 starcat.ink。

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
| Direct 分支不对 | 停止；询问是否切到 main，或是否仅为诊断显式跳过分支检查 |
| 本地 tag 已存在 | Direct 重跑使用 `STARCAT_RELEASE_SKIP_TAG=1`；基础发版则判断是否需要删除本地 tag |
| 远端 tag 已存在 | 不要自动删除；删除远端 tag 会影响协作者，必须让用户明确决定 |
| 基础发版在本地 tag 后构建失败 | 默认保留 tag；如果用户想干净重试，再建议 `git tag -d vX.Y.Z` |
| Direct 包缺少 Sparkle | 视为构建/渠道配置问题；先检查 `project.yml` 和 target 设置，再重试 |
| Direct 包带 sandbox entitlement | 停止；Direct 必须非沙箱；检查 target entitlements 和 scheme |
| notarization 失败 | 检查 notarytool 输出和 Apple 凭证；除非用户明确选择，否则不要上传未 notarize 的公开 DMG |
| appcast 合并后缺少新 DMG/版本 | 停止；检查 `appcast-current.xml`、`pages/appcast.xml` 和 `merge-appcast.py` |
| 线上 URL 校验失败 | 停止；检查上传路径、nginx/site 部署、DNS/TLS 和远程文件权限 |

## 已知漂移

`docs/6-发版与上架/SOP-发版流程.md` 当前把 `scripts/release.sh` 写成标准发版路径。按照当前脚本职责，Direct 公开发布应围绕 `scripts/release-direct.sh`。如果用户要求更新发版文档，要明确区分这两条路径。

根目录 `Makefile` 当前暴露 `make release` 和 `make release-dry-run`，它们调用 `scripts/release.sh`，但还没有 `release-direct` target。如果用户要求改善发版易用性，应提议新增明确的 `release-direct` 和 `release-direct-dry-run` target，而不是重定义 `make release`。
