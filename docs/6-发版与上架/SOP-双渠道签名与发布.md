# SOP-双渠道签名与发布

> 创建：2026-07-08
> 适用：Starcat App Store 版与 Direct 官网 DMG 版。
> 目标：同一代码仓库维护两套独立分发产物，签名、支付、更新和审核边界互不污染。
> 新 Mac 从零准备 Xcode、证书、notary profile 与 Sparkle key：见 `SOP-新Mac开发发布环境搭建.md`。

## 1. 当前渠道边界

| 渠道 | Target / Scheme | Bundle ID | 签名 | 支付 | 更新 |
|------|-----------------|-----------|------|------|------|
| App Store | `Starcat` | `com.starcat.app.store` | `Apple Distribution` | StoreKit / Apple IAP | App Store |
| Direct | `StarcatDirect` | `com.starcat.app.direct` | `Developer ID Application` | License API / Creem / 后续 Waffo | Sparkle + DMG |

`scripts/release-store.sh` 是 Apple Developer 账号接入前的 legacy ad-hoc DMG 入口，默认禁用。正式发布只使用 `scripts/release-direct.sh` 或 `scripts/package-appstore.sh`。

工程已通过 `STARCAT_DISTRIBUTION` 区分运行时渠道：

- App Store build：`appstore`，不展示 Direct 授权码、外部 checkout、Sparkle。
- Direct build：`direct`，不展示 StoreKit 商品、恢复购买、Apple 订阅管理。

## 2. 证书用途

当前本机应至少能看到这些 identity：

```bash
security find-identity -v -p codesigning
security find-identity -v
```

| 证书 | 用途 |
|------|------|
| `Apple Development` | Debug / 本机运行 / 测试 |
| `Apple Distribution` | App Store archive / 上传 App Store Connect |
| `3rd Party Mac Developer Installer` | App Store `.pkg` 导出；当前 Starcat 先走 `.xcarchive`，暂不直接用 |
| `Developer ID Application` | Direct `.app` 签名、notarization |
| `Developer ID Installer` | Direct `.pkg` 安装包；当前 Starcat DMG 暂不直接用 |

Apple 官方说明：Developer ID 用于 Mac App Store 外分发，Gatekeeper 会检查 Developer ID 签名；macOS Mojave 之后公开分发还应提交 notarization。证书类型和上传方式见 Apple 官方文档：

- https://developer.apple.com/macos/distribution/
- https://developer.apple.com/developer-id/
- https://developer.apple.com/help/account/certificates/certificates-overview/
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/

## 3. 本机一次性配置

### 3.1 Xcode 账号

1. Xcode → Settings → Accounts。
2. 登录 Apple Developer 账号。
3. 选择 Team，确认 Team ID。
4. Download Manual Profiles。

当前正式 Team ID：

```text
8WCUMGCWMB
```

### 3.2 本地私密构建配置

`Configs/Secrets.xcconfig` 不进 git，按模板维护：

```bash
cp Configs/Secrets.xcconfig.template Configs/Secrets.xcconfig
```

建议至少填：

```xcconfig
DEVELOPMENT_TEAM = 8WCUMGCWMB
CODE_SIGN_IDENTITY = Apple Development
```

`CODE_SIGN_IDENTITY` 在模板里只建议用于本机 Debug。正式 Direct 发布默认使用 `Developer ID Application: liwen gong (8WCUMGCWMB)`；未来换 Team / CI keychain 时，再用 `STARCAT_DIRECT_SIGN_IDENTITY` 覆盖。

### 3.3 notarytool profile

Direct notarization 推荐使用 Keychain profile，不把 app-specific password 放进命令历史：

```bash
xcrun notarytool store-credentials starcat-notary \
  --apple-id "你的 Apple ID 邮箱" \
  --team-id "8WCUMGCWMB" \
  --password "App-specific password"
```

验证：

```bash
xcrun notarytool history --keychain-profile starcat-notary
```

`No submission history.` 表示凭证可用但还没有提交历史，不是错误。

## 4. App Store 版发布

### 4.1 App Store Connect 后台

1. Certificates：确认 `Apple Distribution` 已安装到本机 Keychain。
2. Identifiers：确认 Bundle ID `com.starcat.app.store`。
3. App Store Connect：创建 Starcat App，Bundle ID 选 `com.starcat.app.store`。
4. In-App Purchases / Subscriptions：创建 StoreKit 商品，Product ID 必须与代码中的 `ProProductID` 对齐。
5. Apple IAP 直接付费订阅，不走 Creem。

### 4.2 本地 archive

```bash
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB \
./scripts/package-appstore.sh
```

脚本会验证：

- 构建的是 `Starcat` scheme。
- `STARCAT_DISTRIBUTION=appstore`。
- Bundle ID 是 `com.starcat.app.store`。
- App Store 包不包含 `Sparkle.framework`。
- App Store 包包含 sandbox entitlement。

Automatic Signing 生成的 `.xcarchive` 是分发前中间产物，可以保留 Apple Development
签名和开发 profile。真正的 App Store Distribution 签名与 Store profile 由 Xcode 在
`app-store-connect` export / Organizer Distribute 阶段统一替换，不能只看 archive 判断最终签名。

如需“打包但暂不上传”，本地导出最终 `.pkg`：

```bash
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB \
STARCAT_APPSTORE_EXPORT=1 \
STARCAT_APPSTORE_ALLOW_PROVISIONING_UPDATES=1 \
STARCAT_APPSTORE_SKIP_OPEN=1 \
./scripts/package-appstore.sh
```

产物为 `dist/appstore/export/Starcat.pkg`。脚本会解包检查主 App、Widget、`codebase.bin`
全部使用 Apple Distribution，profile 不含开发设备，并验证 Installer 与深度签名；
`destination=export` 不会上传 App Store Connect。

### 4.3 上传

第一版建议用 Xcode Organizer 或 Transporter 手动上传，避免自动脚本把不完整物料提交到 App Store Connect。

流程：

1. Xcode → Window → Organizer。
2. 选择 `dist/appstore/Starcat-AppStore.xcarchive`。
3. Validate App。
4. Distribute App → App Store Connect → Upload。
5. App Store Connect 中等待 processing 完成。

## 5. Direct 版发布

### 5.1 本地打包验证

正式公开分发必须使用 Developer ID 签名并 notarize：

```bash
STARCAT_NOTARIZE=1 \
STARCAT_NOTARY_PROFILE=starcat-notary \
STARCAT_SPARKLE_PUBLIC_ED_KEY="你的 Sparkle EdDSA 公钥" \
./scripts/package-direct.sh 1.0.0
```

如果本机已配置 `Configs/Secrets.xcconfig` 中的 `STARCAT_SPARKLE_PUBLIC_ED_KEY`，则本地打包可简化为：

```bash
STARCAT_NOTARIZE=1 STARCAT_NOTARY_PROFILE=starcat-notary ./scripts/package-direct.sh 1.0.0
```

脚本会验证：

- 构建的是 `StarcatDirect` scheme。
- `STARCAT_DISTRIBUTION=direct`。
- Bundle ID 是 `com.starcat.app.direct`。
- Direct 包不包含 sandbox entitlement。
- Direct 包包含 `Sparkle.framework`。
- `STARCAT_NOTARIZE=1` 时签名身份必须是 `Developer ID Application`。
- DMG 在提交 notarization 前使用同一 `Developer ID Application` 签名。
- notarization 通过后执行 `stapler staple`、`stapler validate`、`spctl --assess --type open --context context:primary-signature`，并重新计算最终 SHA256。

临时内部验证可以跳过 notarization：

```bash
./scripts/package-direct.sh 1.0.0
```

公开发布不要跳过。

### 5.2 Direct 一键发布

```bash
STARCAT_NOTARIZE=1 \
STARCAT_NOTARY_PROFILE=starcat-notary \
STARCAT_SPARKLE_PUBLIC_ED_KEY="你的 Sparkle EdDSA 公钥" \
./scripts/release-direct.sh 1.0.0
```

dong4j 当前本机已配置 SSH、Sparkle 公钥、Developer ID 默认签名和 `starcat-notary`，正式发布最简命令是：

```bash
STARCAT_NOTARIZE=1 ./scripts/release-direct.sh 1.0.0
```

如果 Apple notarization 已收到 Submission ID 但 `--wait` 网络超时，等状态变成 `Accepted` 后续跑：

```bash
STARCAT_NOTARIZE=1 STARCAT_RELEASE_SKIP_TAG=1 STARCAT_NOTARY_SUBMISSION_ID=<submission-id> ./scripts/release-direct.sh 1.0.0
```

`release-direct.sh` 会执行：

1. 检查分支和工作区。
2. 创建并推送 `v<version>` tag。
3. 部署 nginx 配置。
4. 部署官网静态页。
5. 调 `package-direct.sh` 生成 notarized DMG。
6. 上传 DMG、SHA256、appcast。
7. 校验线上 appcast、DMG、changelog。

### 5.3 GitHub Release（本机手动上传）

Direct 脚本完成、`v<version>` 已推送、DMG 已通过 notarization 且线上 URL 校验成功后，
还需要把 Direct 安装包上传到同一 tag 的 GitHub Release。该步骤使用本机 GitHub CLI，
不使用 GitHub Actions。

先检查登录状态和远端 Release 是否已存在：

```bash
gh auth status
gh release view v1.0.0
```

从 `supports/starcat-pro/CHANGELOG.md` 提取目标版本英文内容到临时文件后执行：

```bash
gh release create v1.0.0 \
  dist/direct/downloads/Starcat-1.0.0-arm64.dmg \
  dist/direct/downloads/Starcat-1.0.0-arm64.dmg.sha256 \
  --verify-tag \
  --title "Starcat 1.0.0" \
  --notes-file "<临时发布说明文件>"
```

验证 Release 和资产：

```bash
gh release view v1.0.0 \
  --json tagName,name,isDraft,isPrerelease,url,assets
```

如果 Release 或同名资产已存在，停止并确认恢复策略；不要默认使用 `--clobber`
覆盖公开资产。GitHub Release 至少上传 notarized DMG 与对应 SHA256，不上传
DerivedData、构建日志、未公证包或含凭据文件。

如果只是内部临时分发未公证包，必须显式声明：

```bash
STARCAT_RELEASE_ALLOW_UNNOTARIZED=1 ./scripts/release-direct.sh 1.0.0
```

## 6. 发版前检查

### 6.1 从 `dev` 进入 `main`

发版整改、迁移收口和编译警告修复均在 `dev` 完成。迁移测试、全量测试、App Store / Direct
Release 构建和脚本静态检查通过后，再按分支规范核对工作区和远端状态：

```bash
git status --short --branch
git worktree list --porcelain
git fetch --prune
git rev-list --left-right --count main...dev
```

只有工作区干净、`dev` 已提交、`main` 与 `dev` 未分叉且已获得分支操作授权时，才执行：

```bash
git switch main
git merge --ff-only dev
```

`git push origin main`、tag、打包和上传仍是独立发布动作，必须获得对应授权。
如果进入 `main` 后发现代码问题，返回 `dev` 修复并重新跑门禁，不直接在 `main` 开展日常整改。

### 6.2 双渠道构建配置

```bash
xcodegen generate
```

### 6.3 App Store archive

```bash
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB ./scripts/package-appstore.sh
```

只在本地生成 Distribution 签名的 `.pkg`，不上传：

```bash
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB \
STARCAT_APPSTORE_EXPORT=1 \
STARCAT_APPSTORE_ALLOW_PROVISIONING_UPDATES=1 \
STARCAT_APPSTORE_SKIP_OPEN=1 \
./scripts/package-appstore.sh
```

### 6.4 Direct notarized DMG

```bash
STARCAT_NOTARIZE=1 \
STARCAT_NOTARY_PROFILE=starcat-notary \
./scripts/package-direct.sh 1.0.0
```

### 6.5 签名诊断

```bash
APP="dist/direct/DerivedData/Build/Products/Release/Starcat.app"

codesign -dvvv --entitlements :- "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --verbose=2 "dist/direct/downloads/Starcat-1.0.0-arm64.dmg"
spctl --assess --type open --context context:primary-signature --verbose "dist/direct/downloads/Starcat-1.0.0-arm64.dmg"
```

### 6.6 Notary 诊断

```bash
xcrun notarytool history --keychain-profile starcat-notary
xcrun notarytool log <submission-id> --keychain-profile starcat-notary
```

## 7. 常见问题

### 7.1 `No Keychain password item found for profile`

说明 `starcat-notary` 没有保存到 Keychain。重新执行：

```bash
xcrun notarytool store-credentials starcat-notary \
  --apple-id "你的 Apple ID 邮箱" \
  --team-id "8WCUMGCWMB" \
  --password "App-specific password"
```

### 7.2 `STARCAT_NOTARIZE=1 时签名身份不能是 ad-hoc`

Direct 正式公证不能用 `-` ad-hoc 签名。当前脚本默认使用：

```bash
Developer ID Application: liwen gong (8WCUMGCWMB)
```

如果未来换证书或 CI keychain，再显式传：

```bash
STARCAT_DIRECT_SIGN_IDENTITY="Developer ID Application: <name> (<team-id>)"
```

### 7.3 App Store 包包含 Sparkle

说明 target / scheme 用错，或依赖被错误加进 `Starcat`。App Store 只允许 `Starcat` target，不应链接 Sparkle。

### 7.4 Direct 包检测到 sandbox entitlement

说明 Direct target 误用了 `Starcat.entitlements`。Direct 必须使用 `Starcat/StarcatDirect.entitlements`。

### 7.5 App Store archive 失败但 Debug 能跑

优先检查：

```bash
security find-identity -v -p codesigning
```

确认存在 `Apple Distribution: ... (8WCUMGCWMB)`，并确认 Xcode 已登录对应 Team。

## 8. 不做的事

- 不让 App Store 包出现 Creem、License Key、官网购买入口。
- 不让 Direct 包出现 StoreKit 商品购买、恢复购买、Apple 订阅管理。
- 不在 `release-direct.sh` 自动上传 App Store 包。
- 不把 app-specific password 写进仓库、脚本或 `.env`。
