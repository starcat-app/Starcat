# Direct 打包教程

> 适用渠道：官网 DMG / Sparkle 自动更新  
> 对应脚本：`scripts/package-direct.sh`  
> 构建目标：`StarcatDirect`  
> Bundle ID：`com.starcat.app.direct`

## 1. 前置条件

- 已有 Apple Developer ID Application 证书。
- 已生成 Sparkle EdDSA key，并把公钥写入 `Configs/Secrets.xcconfig`：

```xcconfig
STARCAT_SPARKLE_PUBLIC_ED_KEY = <public-ed-key>
```

- `pages/appcast.xml` 可部署到 `https://starcat.ink/appcast.xml`。
- 公开发版前准备好 notarization 凭证：

```bash
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="XXXXXXXXXX"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

## 2. 本地生成 DMG

```bash
./scripts/package-direct.sh 0.1.0
```

脚本会生成：

```text
dist/direct/downloads/Starcat-0.1.0-arm64.dmg
dist/direct/downloads/Starcat-0.1.0-arm64.dmg.sha256
dist/direct/xcodebuild-direct.log
```

脚本内置检查：

- `STARCAT_DISTRIBUTION == direct`
- Direct 包包含 `Sparkle.framework`
- DMG 生成后有 SHA256

## 3. 正式公开发版

正式公开分发时启用 notarization：

```bash
STARCAT_NOTARIZE=1 ./scripts/package-direct.sh 0.1.0
```

脚本会执行：

1. `xcrun notarytool submit --wait`
2. `xcrun stapler staple`
3. `spctl --assess --type open`

## 4. 更新 appcast

把 DMG 放到 `dist/direct/downloads/` 后，可让脚本调用 Sparkle 的 `generate_appcast`：

```bash
STARCAT_GENERATE_APPCAST=1 \
STARCAT_DOWNLOAD_BASE_URL="https://starcat.ink/downloads/" \
./scripts/package-direct.sh 0.1.0
```

脚本会生成并覆盖：

```text
pages/appcast.xml
```

部署时需要同时上传：

- `pages/appcast.xml` -> `https://starcat.ink/appcast.xml`
- `dist/direct/downloads/Starcat-0.1.0-arm64.dmg` -> `https://starcat.ink/downloads/Starcat-0.1.0-arm64.dmg`

## 5. Sparkle 验证

首个公开版本建议先保持 `pages/appcast.xml` 为空 feed。第二个版本开始验证完整更新链路：

1. 安装旧版 Direct DMG。
2. 部署新版 DMG 和新版 `appcast.xml`。
3. 打开 Starcat Direct。
4. 菜单 `操作 -> 检查更新...`。
5. 确认 Sparkle 弹窗展示新版并可安装。

## 6. 常见问题

### 检查更新菜单是灰色

通常是 `STARCAT_SPARKLE_PUBLIC_ED_KEY` 为空。Direct 版会展示菜单，但没有公钥时不会启动 Sparkle updater。

### Notarization 失败

看 `notarytool` 输出中的 issue。常见原因：

- 使用了 ad-hoc 签名而非 Developer ID。
- `APPLE_APP_PASSWORD` 不是 app-specific password。
- 嵌入框架未正确签名。

### appcast 不更新

确认：

- `STARCAT_GENERATE_APPCAST=1`
- `STARCAT_DOWNLOAD_BASE_URL` 以 `/downloads/` 结尾
- DMG 已 notarize/staple 后再生成 appcast
