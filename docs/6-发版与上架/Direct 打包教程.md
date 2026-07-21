# Direct 打包教程

> 适用渠道：官网 DMG / Sparkle 自动更新  
> 对应脚本：`scripts/package-direct.sh`  
> 构建目标：`StarcatDirect`  
> Bundle ID：`com.starcat.app.direct`

## 1. 前置条件

- 已有 Apple Developer ID Application 证书。
- 已生成 Sparkle EdDSA key，并把公钥写入 `Configs/Secrets.xcconfig`。
- `pages/appcast.xml` 可部署到 `https://starcat.ink/appcast.xml`。
- 公开发版前准备好 notarization 凭证：

```bash
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="XXXXXXXXXX"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

## 2. 生成 Sparkle EdDSA key

Sparkle 的更新包签名使用 EdDSA key pair。私钥由 `generate_keys` 写入本机 Keychain，公钥写入 Direct app 的 `SUPublicEDKey`。

先找到 Xcode 拉下来的 Sparkle 工具：

```bash
find ~/Library/Developer/Xcode/DerivedData \
  -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' \
  -type f \
  | head -1
```

如果能找到路径，直接执行它：

```bash
"/Users/dong4j/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
```

工具会输出 `SUPublicEDKey`。把这个值写入本地私密配置：

```xcconfig
STARCAT_SPARKLE_PUBLIC_ED_KEY = <SUPublicEDKey 输出值>
```

推荐写入 `Configs/Secrets.xcconfig`，不要写入 `Configs/Build.xcconfig`：

```bash
cp Configs/Secrets.xcconfig.template Configs/Secrets.xcconfig
open -a TextEdit Configs/Secrets.xcconfig
```

`Configs/Secrets.xcconfig` 已被 `.gitignore` 排除，不应提交。私钥保存在 Keychain，丢失后旧版本 appcast / 更新包签名链路会受影响，需要妥善备份当前 Mac 的 Keychain。

### 多台 Mac / CI 打包

同一个 Direct 更新链路必须使用同一组 Sparkle key：

| 内容 | 用途 | 是否可共享 |
|------|------|------------|
| `SUPublicEDKey` | 内置到 App，用于校验更新包签名 | 可以写入各构建机的 `Configs/Secrets.xcconfig` |
| EdDSA 私钥 | 生成 appcast / 签更新包 | 只能通过安全方式转移，不能进 git |

如果另一台 Mac 只是构建 App，不生成 appcast、不签更新包，只要注入相同 `SUPublicEDKey` 即可。  
如果另一台 Mac 需要生成 appcast 或签更新包，必须导入同一份私钥。

在当前 Mac 导出私钥：

```bash
generate_keys -x sparkle-private-key
```

在另一台 Mac 导入私钥：

```bash
generate_keys -f sparkle-private-key
```

`sparkle-private-key` 是敏感文件，必须放在加密存储或密钥管理系统中，不允许提交到 git。不要在不同 Mac 上重新运行 `generate_keys` 生成不同 key；旧版 App 内置的是旧公钥，无法校验新私钥签名的更新包。除非专门做 Sparkle key rotation，否则发布后应长期保留同一份私钥。

写入后重新构建 Direct 版：

```bash
make run-direct
```

菜单 `操作 -> 检查更新...` 应变为可点击。

如果 `find` 找不到 `generate_keys`，先构建一次 Direct target 让 Xcode 解析 Sparkle package，或从 Sparkle GitHub Release 下载 `Sparkle-for-Swift-Package-Manager.zip` 后运行其中的 `bin/generate_keys`。

## 3. 本地生成 DMG

```bash
./scripts/package-direct.sh 1.0.0
```

脚本会生成：

```text
dist/direct/downloads/Starcat-1.0.0-arm64.dmg
dist/direct/downloads/Starcat-1.0.0-arm64.dmg.sha256
dist/direct/xcodebuild-direct.log
```

脚本内置检查：

- `STARCAT_DISTRIBUTION == direct`
- `CFBundleShortVersionString` 等于传入版本号
- `CFBundleVersion` 等于本次 Direct 打包 build number
- Direct 包包含 `Sparkle.framework`
- Direct 包不包含 `com.apple.security.app-sandbox`
- 内置 `codebase.bin` 使用 Developer ID + hardened runtime 签名
- DMG 生成后有 SHA256

`create-dmg` 会调用 Finder AppleScript 写入背景图、图标位置和窗口大小。Finder 偶发繁忙时可能报 `AppleEvent已超时 (-1712)`；项目脚本默认把 Finder AppleScript timeout 提升到 600 秒，并重试 3 次。必要时可临时加长：

```bash
STARCAT_DMG_APPLESCRIPT_TIMEOUT_SECONDS=1200 \
STARCAT_DMG_RETRY_COUNT=5 \
STARCAT_DMG_RETRY_SLEEP_SECONDS=90 \
./scripts/package-direct.sh 1.0.0
```

## 4. 正式公开发版

正式公开分发时启用 notarization：

```bash
STARCAT_NOTARIZE=1 ./scripts/package-direct.sh 1.0.0
```

脚本默认使用 `Developer ID Application: liwen gong (8WCUMGCWMB)` 签名；只有未来换 Team / CI keychain 时才需要传 `STARCAT_DIRECT_SIGN_IDENTITY` 覆盖。

脚本会执行：

1. 用 `Developer ID Application` 签名 DMG 外层容器
2. `xcrun notarytool submit --wait`
3. `xcrun stapler staple` 与 `xcrun stapler validate`
4. `spctl --assess --type open --context context:primary-signature`
5. 在 staple 后重新计算最终 DMG SHA256

仅需临时走通后续发布流程时，可以显式允许未公证 DMG：

```bash
STARCAT_RELEASE_ALLOW_UNNOTARIZED=1 \
STARCAT_RELEASE_SKIP_TAG=1 \
./scripts/release-direct.sh 1.0.0
```

对应的 Make 快捷入口：

```bash
make release-direct-unnotarized VERSION=1.0.0
```

未公证模式会忽略 `STARCAT_NOTARY_SUBMISSION_ID` 和本地残留的 `.notary-submission-id`，重新生成 DMG 与 appcast。该产物只用于内部临时验证，不能作为正式公开发布包。

## 5. 发布 Direct 更新

正式发布或端到端测试时，使用发布编排脚本。脚本内置 `--help`，忘记用法时先看帮助：

```bash
./scripts/release-direct.sh --help
STARCAT_NOTARIZE=1 ./scripts/release-direct.sh 1.0.0
```

dong4j 当前本机已配置 SSH、Sparkle 公钥、Developer ID 默认签名和 `starcat-notary`，正式发布时直接使用上面这条即可。脚本未显式传 `STARCAT_NOTARY_PROFILE` 时会默认使用 `starcat-notary`。

它会串联执行：

1. 确认当前分支是 `main` 且工作区干净。
2. 创建并推送 `v1.0.0` annotated tag。
3. 生成并部署官网 changelog 页面。
4. 部署 `pages/direct/starcat.ink.conf` 并 reload nginx。
5. 调用 `scripts/package-direct.sh 1.0.0` 完成本地 Direct 打包。
6. 生成 Sparkle appcast。
7. 上传 `pages/appcast.xml` 到 `https://starcat.ink/appcast.xml`。
8. 上传 DMG / SHA256 到 `https://starcat.ink/downloads/`。
9. 通过 `STARCAT_RELEASE_HOST` 在发布服务器上执行 `curl -I`，校验线上 appcast、DMG 和 changelog 可访问，避免本机 TUN / Fake-IP / 代理分流造成 TLS 误判。

如果 `notarytool --wait` 在拿到 Submission ID 后网络超时，先等 Apple 状态变成 `Accepted`，再复用已有 DMG 续跑：

```bash
xcrun notarytool info <submission-id> --keychain-profile starcat-notary
STARCAT_NOTARIZE=1 STARCAT_RELEASE_SKIP_TAG=1 STARCAT_NOTARY_SUBMISSION_ID=<submission-id> ./scripts/release-direct.sh 1.0.0
```

默认远程配置与 `pages/deploy.sh` 保持一致：

```text
STARCAT_RELEASE_HOST=aliyun
STARCAT_RELEASE_WEB_DIR=/var/www/starcat
STARCAT_DOWNLOAD_BASE_URL=https://starcat.ink/downloads/
```

演练发布命令，不实际上传：

```bash
STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh 1.0.0
```

如果 tag 已存在，只想重跑打包、上传和线上校验：

```bash
STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh 1.0.0
```

如果只重跑 Direct 更新文件发布，跳过 tag 和官网部署：

```bash
STARCAT_RELEASE_SKIP_TAG=1 \
STARCAT_RELEASE_SKIP_NGINX=1 \
STARCAT_RELEASE_SKIP_SITE=1 \
./scripts/release-direct.sh 1.0.0
```

底层打包脚本仍可单独用于本地排查：

```bash
STARCAT_GENERATE_APPCAST=1 \
STARCAT_DOWNLOAD_BASE_URL="https://starcat.ink/downloads/" \
./scripts/package-direct.sh 1.0.0
```

本地会生成并覆盖：

```text
pages/appcast.xml
dist/direct/downloads/appcast.xml
dist/direct/downloads/Starcat-1.0.0-arm64.dmg
dist/direct/downloads/Starcat-1.0.0-arm64.dmg.sha256
```

脚本生成 appcast 时只会把本次 `package-direct.sh` 产出的 DMG 放入临时输入目录。这样可以避免 `dist/direct/downloads/` 中遗留的旧测试包被 Sparkle 扫描进去，造成 `appcast.xml` 同时出现过期版本或未签名版本。

## 6. Sparkle 验证

正式首发 `1.0.0` 已内置 Sparkle。验证应用内更新时，需要在 `1.0.0` 之后构建一个更高的临时版本。

如果当前安装的 Direct 版已经是 `1.0.0`，需要构建一个更高版本作为测试更新包，例如：

```bash
STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh 1.0.1
```

这样 appcast 会指向 `Starcat-1.0.1-arm64.dmg`。测试完成后，如果 `1.0.1` 只是临时测试包，不要把它当正式版本对外发布。

完整更新链路验证：

1. 安装旧版 Direct DMG。
2. 部署新版 DMG 和新版 `appcast.xml`。
3. 打开 Starcat Direct。
4. 菜单 `操作 -> 检查更新...`。
5. 确认 Sparkle 弹窗展示新版并可安装。

自动检查验证：

1. 启动旧版 Direct，看到 Sparkle 权限弹窗时选择 `自动检查`。
2. 确认 `https://starcat.ink/appcast.xml` 已部署并指向更高版本。
3. 退出并重新打开旧版 Direct。
4. Sparkle 的自动检查有调度间隔，默认不是每次启动都立刻弹窗；本地测试时，手动 `操作 -> 检查更新...` 是确定性验证，自动检查用于确认权限弹窗和后台调度未报错。

## 7. 常见问题

### 检查更新菜单是灰色

通常是 `STARCAT_SPARKLE_PUBLIC_ED_KEY` 为空。Direct 版会展示菜单，但没有公钥时不会启动 Sparkle updater。

可检查当前构建产物：

```bash
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  build/DerivedData-NoSandbox/Build/Products/Debug/Starcat.app/Contents/Info.plist
```

如果输出为空，按第 2 节生成并写入 `Configs/Secrets.xcconfig` 后重新 `make run-direct`。

### Notarization 失败

看 `notarytool` 输出中的 issue。常见原因：

- 使用了 ad-hoc 签名而非 Developer ID。
- `APPLE_APP_PASSWORD` 不是 app-specific password。
- 嵌入框架未正确签名。

### appcast 不更新

确认：

- 使用 `scripts/release-direct.sh` 发布，或单独运行 `package-direct.sh` 时设置 `STARCAT_GENERATE_APPCAST=1`
- `STARCAT_DOWNLOAD_BASE_URL` 以 `/downloads/` 结尾
- DMG 已 notarize/staple 后再生成 appcast
- nginx 已部署 `pages/direct/starcat.ink.conf` 中 `/appcast.xml` 的 no-cache 规则
- 测试 / 生产落地页部署方式见 `docs/6-发版与上架/Direct-测试与生产环境隔离.md`
