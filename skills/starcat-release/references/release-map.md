# Starcat 发版脚本地图

处理 Starcat 发版任务时使用这份参考。它记录当前仓库内各发版脚本的职责、环境变量和失败恢复方式。

## 脚本职责

| 文件 | 职责 | 备注 |
|---|---|---|
| `scripts/package-appstore.sh` | App Store archive 构建入口 | 构建并验证 `Starcat` archive；上传由 Xcode Organizer / Transporter 完成 |
| `scripts/release-direct.sh` | Direct 公开发布编排入口 | 完整路径：tag、官网/nginx 部署、Direct DMG、Sparkle appcast、上传、线上校验 |
| `scripts/release-direct-development.sh` | Direct Beta 发布及恢复 | `X.Y.Z-beta.N`；prerelease、Beta feed 和官网双语更新日志；支持 `--resume` |
| `scripts/release-store.sh` | 历史 ad-hoc 内测发版入口 | legacy 且默认禁用；需 `STARCAT_ALLOW_LEGACY_RELEASE=1`，不用于正式双渠道发布 |
| `scripts/package-direct.sh` | Direct 包构建入口 | 构建 `StarcatDirect`，校验 Sparkle 与非沙箱 entitlement，生成 DMG/SHA，可选 notarization/appcast |
| `scripts/build-dmg.sh` | legacy 内测 DMG 构建入口 | 仅供 `release-store.sh` 历史流程使用，输出到 `build/dmg/` |
| `scripts/publish-direct-github-release.py` | GitHub 草稿上传、回读 SHA256 校验、公开及安全续跑 | 只上传 DMG/SHA256，不操作官网 appcast |
| `scripts/verify-direct-release-artifacts.py` | 两种 Direct 恢复入口共用的只读校验 | 检查原 tag、最终 DMG/SHA256、公证票据和当前 appcast；不依赖当前 HEAD |
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

该脚本只允许使用 `/Applications/Xcode.app/Contents/Developer` 中的正式版 Xcode。
必须显式传入 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；Beta、RC、Preview
或其他 Xcode 路径必须在删除旧产物前失败，不能用它们产生待审核构建。

它会校验：

- Xcode 为标准路径下的正式版，并记录 version / build；
- `STARCAT_DISTRIBUTION=appstore`；
- Bundle ID 为 `com.starcat.app.store`；
- App Store 包包含 sandbox entitlement；
- App Store 包不包含 `Sparkle.framework`；
- 主 App、内置 `codebase.bin` 的签名与 dSYM UUID 一致性。

日常命令：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make package-appstore
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
6. 带 `STARCAT_GENERATE_APPCAST=1` 调用 `package-direct.sh`；
7. 校验最终 DMG/SHA/appcast-current 文件，并合并本地 appcast；
8. 通过本机 `gh` 创建 GitHub 草稿、上传 DMG/SHA256、回读附件验证 SHA256 后公开；
9. 生成并部署官网 changelog、静态页和 nginx；
10. 确认 GitHub 下载可用后，只上传官网 appcast；
11. 跟随重定向校验线上 appcast、GitHub DMG 和 changelog；
12. 用正式 DMG 的 SHA256 更新 Homebrew Cask，按授权提交并验证 tap。

生成 appcast 不要求远端附件已存在；公布清单要求 GitHub 附件已验证并公开。
DMG/SHA256 不再通过 rsync 上传阿里云，appcast 更新地址仍为 `https://starcat.ink/appcast.xml`。

重要环境变量：

| 变量 | 含义 |
|---|---|
| `STARCAT_NOTARIZE=1` | 在 `package-direct.sh` 内启用 notarization；公开发布建议开启 |
| `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD` | 开启 notarization 时必需 |
| `STARCAT_RELEASE_HOST` | SSH host，默认 `aliyun2` |
| `STARCAT_RELEASE_WEB_DIR` | 远程网站根目录，默认 `/var/www/starcat` |
| `STARCAT_SITE_ROOT` | 独立官网仓库路径，默认 `supports/starcat-site` |
| `STARCAT_DOWNLOAD_BASE_URL` | DMG URL 前缀，默认 `https://github.com/starcat-app/Starcat/releases/download/v<version>/` |
| `STARCAT_RELEASE_REUSE_ARTIFACTS=1` | 等同 `--resume`，只恢复 GitHub 与 appcast；不打 tag、不构建、不部署官网静态页，不要求当前分支或源码干净 |
| `STARCAT_RELEASE_SKIP_TAG=1` | tag 已存在但尚需打包/续跑公证时使用；不会跳过打包，最终产物已就绪应使用 `--resume` |
| `STARCAT_RELEASE_SKIP_NGINX=1` | 跳过 nginx 部署 |
| `STARCAT_RELEASE_SKIP_SITE=1` | 跳过 changelog 和静态官网部署 |
| `STARCAT_RELEASE_DRY_RUN=1` | 打印副作用命令，并跳过状态写入、部署、构建、上传和线上校验 |

## Homebrew Cask 发布契约

`supports/homebrew-starcat` 是独立 Git 仓库。Direct 正式发布的最后阶段必须使
`Casks/starcat.rb` 与线上 DMG 保持一致：

```ruby
version "<X.Y.Z>"
sha256 "<Starcat-X.Y.Z-arm64.dmg 的真实 SHA256>"
url "https://github.com/starcat-app/Starcat/releases/download/v#{version.csv.first}/Starcat-#{version.csv.first}-arm64.dmg"
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

### 最终产物已经就绪

```bash
./scripts/release-direct.sh X.Y.Z --resume
./scripts/release-direct-development.sh X.Y.Z-beta.N --resume
```

两个入口均先校验：

- DMG/SHA256 文件名、真实摘要、appcast 的唯一 item、营销版本、构建号、下载 URL、
  附件大小、Sparkle 签名字段和更新说明；
- 本地 tag 对象与远端同名 tag 相同，并回显原 tag 的 commit；不要求当前 HEAD 等于 tag；
- 已有公证票据和 Gatekeeper 接受状态；只 validate/assess，不重新公证、签名或 staple。

恢复不会触碰源码脏状态，也不会创建或推送 tag。Beta 恢复额外从同次快照补发并核验官网双语日志，正式恢复只处理 GitHub 及正式/Beta feed；
官网静态页和 Homebrew 若尚未发布，作为原发布范围内的剩余阶段单独处理，不能报告整版完成。

### Beta 契约与验收

新构建要求 `dev` 和干净工作区，并设置 `STARCAT_NOTARIZE=1`。
版本号使用 `X.Y.Z-beta.N`（N 为无前导零的正整数），App 营销版本保持 `X.Y.Z`。
最终产物在 `dist/direct-development/downloads/`：
`Starcat-X.Y.Z-arm64.dmg`、同名 `.sha256`、`appcast-current.xml`。
Beta 允许使用 Direct 对应版本的待发布 Changelog。

完成必须同时核实：GitHub `isDraft=false`、`isPrerelease=true`，两份附件下载摘要正确，
公开下载地址可用，线上 `appcast-development.xml` 与本地发布内容相同；
`changelog.html` 与 `changelog-zh.html` 从同次说明快照生成，显示本次 `X.Y.Z Beta N`，
不含未来版本或待发布内容，逐页回读正文与本地逐字节一致。
正式 `appcast.xml`、正式 latest、Homebrew 和 App Store 保持原状。官网仓库的 feed、
日志 HTML 与源目标节改动按当前任务授权单独提交/推送，并完成所有项目 `dev/main` 同步。

仅缺官网日志时，按 `starcat-public-site-and-promo/references/site-promo-map.md`
的定向恢复步骤生成并上传两页，不重跑 DMG 构建或完整官网部署。

### 故障处理

| 失败点 | 建议处理 |
|---|---|
| 新构建工作区不干净 | 展示现状并处理构建范围；若最终产物已就绪，改用 `--resume`，不为上传修改源码 |
| App Store 检测到 Beta/RC/Preview Xcode | 停止；改用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，不复用已生成的待审核包 |
| App Store archive 生成失败 | 停止；检查 `dist/appstore/xcodebuild-appstore.log`、Apple Distribution identity 与 App Store target 配置 |
| Direct 分支不对 | 停止；询问是否切到 main，或是否仅为诊断显式跳过分支检查 |
| 本地 tag 已存在 | 最终产物已就绪用 `--resume`；尚需打包/续跑公证才用 `STARCAT_RELEASE_SKIP_TAG=1`；不改写原 tag |
| 远端 tag 已存在 | 不要自动删除；删除远端 tag 会影响协作者，必须让用户明确决定 |
| legacy 流程在本地 tag 后构建失败 | 默认保留 tag；如果用户想干净重试，再建议 `git tag -d vX.Y.Z` |
| Direct 包缺少 Sparkle | 视为构建/渠道配置问题；先检查 `project.yml` 和 target 设置，再重试 |
| Direct 包带 sandbox entitlement | 停止；Direct 必须非沙箱；检查 target entitlements 和 scheme |
| notarization 失败 | 检查 notarytool 输出和 Apple 凭证；除非用户明确选择，否则不要上传未 notarize 的公开 DMG |
| appcast 合并后缺少新 DMG/版本 | 停止；检查 `appcast-current.xml`、`supports/starcat-site/direct/appcast.xml` 和 `merge-appcast.py` |
| GitHub 上传中断 | 先回读实际状态，保留原产物，使用对应脚本 `--resume`；只补草稿缺失附件 |
| by-tag 查询 404 | 仍需分页读取 Release 列表精确匹配 `tag_name`；不能直接创建草稿 |
| 多份同 tag 草稿 | 停止写操作，核对 ID/归属/附件；不删除未知草稿，不做“删完再原样重跑” |
| 相同逻辑错误再次出现 | 停止原命令的写操作，检查入口调用链并补模拟回归；有新证据后再恢复 |
| GitHub 附件与本地不同 | 停止；不覆盖附件、不公开草稿、不上传 appcast |
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
