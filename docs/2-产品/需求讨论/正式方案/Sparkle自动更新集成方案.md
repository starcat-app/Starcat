# Sparkle 自动更新集成方案

> 创建：2026-07-04
> 状态：**方案待确认，尚未实现**
> 用途：Starcat Direct 官网 DMG 渠道的自动更新方案、App Store 渠道禁用边界与发版流程设计
> 前置阅读：`docs/2-产品/需求讨论/正式方案/Direct分发与LemonSqueezy授权方案.md`、`docs/2-产品/需求讨论/正式方案/StoreKit订阅上架方案.md`、`docs/6-发版与上架/SOP-发版流程.md`

---

## 1. 背景与目标

Starcat 后续会同时支持两个分发渠道：

| 渠道 | 分发方式 | 更新机制 | 约束 |
|------|----------|----------|------|
| App Store | Mac App Store | Mac App Store 更新 | 不允许内置 Sparkle 或其他自更新机制 |
| Direct | 官网下载 DMG | Sparkle appcast 自动更新 | 需要 Developer ID 签名、Notarization、EdDSA 签名与 HTTPS appcast |

本方案目标：

1. 为 Direct build 集成 Sparkle 2，支持用户手动检查更新与后台自动检查更新。
2. 保持 App Store build 审核边界干净，不包含 Sparkle framework、更新菜单、appcast 配置或官网更新引导。
3. 将自动更新接入现有 `release.sh` / `build-dmg.sh` 发版链路，避免人工改 appcast。
4. 与 Direct 授权方案保持一致：Direct build 可以包含官网、License Key、Sparkle；App Store build 只走 StoreKit 和 App Store 更新。

---

## 2. 核心结论

### 2.1 Sparkle 只属于 Direct 渠道

Sparkle 是 Direct 官网分发的自动更新能力，不是 Starcat 全渠道能力。

App Store build 的正确策略不是“运行时禁用 Sparkle”，而是：

1. 不链接 Sparkle framework。
2. 不打包 Sparkle XPC services / helper tools。
3. 不写 Sparkle 相关 `Info.plist` key。
4. 不显示“Check for Updates...”菜单或设置项。
5. 不在 App Store 审核包内出现官网更新、下载 DMG、appcast 等路径。

原因：Apple App Review Guidelines 对 Mac App Store app 的更新机制要求非常明确：Mac App Store app 必须通过 Mac App Store 分发更新，不能使用其他更新机制。Starcat 不能把 Sparkle 当成一个可隐藏的普通 SDK，否则审核风险和后续维护风险都太高。

### 2.2 Direct 与 App Store 要在构建层分离

沿用 Direct 授权文档里的渠道建模：

```swift
enum DistributionChannel {
    case appStore
    case direct
}
```

渠道来源必须来自编译配置或 `Info.plist` 注入，不允许运行时按 receipt、bundle path、是否有 appcast URL 等信号猜测。审核边界必须稳定。

建议配置：

| Build | `STARCAT_DISTRIBUTION` | Sparkle |
|-------|-------------------------|---------|
| App Store build | `appstore` | 不包含 |
| Direct build | `direct` | 包含 |

---

## 3. Sparkle 2 技术事实

### 3.1 推荐版本

实施时建议使用 Sparkle 2 最新稳定版本，并在 `project.yml` 中写明确版本范围。2026-07-04 调研时，Swift Package Index 显示最新稳定版本为 `2.9.4`。

建议：

```yaml
Sparkle:
  url: https://github.com/sparkle-project/Sparkle
  from: "2.9.4"
```

后续升级 Sparkle 应作为发版前专项验证，不要自动漂移到未验证版本。

### 3.2 安全要求

Direct 自动更新至少满足：

1. appcast 和更新包必须通过 HTTPS 分发。
2. Direct app 必须 Developer ID 签名并 notarize。
3. 更新包必须用 Sparkle EdDSA 签名。
4. `Info.plist` 必须包含 `SUPublicEDKey`，用于校验更新包签名。
5. 建议开启 feed 签名能力，降低 appcast 或 release notes 被篡改后的欺骗风险。

一次性密钥流程：

```bash
generate_keys
```

生成结果：

| 内容 | 存放 |
|------|------|
| EdDSA private key | 开发者 Keychain + 离线备份，不提交 |
| EdDSA public key | Direct build 的 `SUPublicEDKey`，可提交 |

### 3.3 Sandboxed app 配置

Starcat 当前已经启用 App Sandbox，并已有 `com.apple.security.network.client`。因此：

1. Direct build 需要启用 Sparkle Installer XPC Service。
2. Direct build 不需要启用 Sparkle Downloader XPC Service。
3. Direct build 需要额外 mach lookup temporary exception，允许 app 与 Sparkle installer tools 通信。

Direct entitlements 增量：

```xml
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
</array>
```

注意：这组 entitlement 不应进入 App Store build。App Store build 不使用 Sparkle，也不需要 Sparkle XPC 通信例外。

---

## 4. Starcat 工程落点

### 4.1 推荐工程结构

推荐在 `project.yml` 中拆出渠道 target / scheme：

```text
Starcat              # App Store / 默认 App target，不含 Sparkle
StarcatDirect        # Direct 官网 DMG target，含 Sparkle
StarcatTests         # 单测 target，默认继续测 Starcat 主 target
```

优点：

1. App Store 产物天然不链接 Sparkle，审核边界最干净。
2. Direct 产物可以独立配置 bundle id、entitlements、Info.plist key、发版脚本。
3. 后续 Lemon Squeezy / License Key UI 也可以复用同一个 Direct target 边界。

备选方案是单 target + 多 configuration 条件编译，但不推荐作为首选。原因是 Sparkle framework 和 Info key 容易被误带进 App Store archive，后续审核排查成本更高。

### 4.2 Bundle ID

建议保留或明确拆分：

| Target | Bundle ID 建议 | 说明 |
|--------|----------------|------|
| App Store | `com.starcat.app` | Mac App Store 正式包 |
| Direct | `com.starcat.app.direct` 或 `com.starcat.app` | 待 dong4j 拍板 |

两种选择的取舍：

| 选择 | 优点 | 风险 |
|------|------|------|
| Direct 也用 `com.starcat.app` | 用户数据路径、Keychain、URL scheme 更统一 | 同机安装 App Store 与 Direct 版本会冲突 |
| Direct 用 `com.starcat.app.direct` | 双版本可并存，渠道边界清楚 | 本地数据、OAuth callback、Keychain group 需要明确迁移 / 共享策略 |

首版建议：如果短期不会让用户同时安装两版，可先保持同一个 bundle id；如果明确要支持双版本并存，应从一开始拆 Direct bundle id。

### 4.3 Info.plist

Direct build 专属 key：

| Key | 示例 | 说明 |
|-----|------|------|
| `SUFeedURL` | `https://starcat.ink/appcast.xml` | Sparkle appcast 地址 |
| `SUPublicEDKey` | `<base64 public key>` | EdDSA 公钥 |
| `SUEnableInstallerLauncherService` | `YES` | sandbox app 必需 |
| `SUVerifyUpdateBeforeExtraction` | `YES` | 建议开启，先校验再解压 |
| `SURequireSignedFeed` | `YES` | 建议开启，要求 appcast / release notes 签名 |

App Store build 不写以上任何 key。

### 4.4 Swift 接入点

新增一个 Direct-only 的轻量封装：

```text
Starcat/Core/Updates/
  DirectUpdateController.swift
```

职责：

1. 持有 `SPUStandardUpdaterController`。
2. 启动 Sparkle updater。
3. 暴露 `checkForUpdates()` 给菜单命令调用。
4. 保持对 App 主业务无侵入。

SwiftUI 菜单接入：

```text
StarcatAppCommands
  App Store build: 不显示更新菜单
  Direct build: 显示 Check for Updates...
```

不建议首版自定义 Sparkle UI。Sparkle 标准 UI 已覆盖更新说明、下载、安装、重启提示；Starcat 只需要菜单入口与后台检查。

### 4.5 设置页入口

首版不建议新增复杂设置页。最低可用形态：

1. Direct build 在 App 菜单提供“Check for Updates...”。
2. Sparkle 自己处理自动检查权限与更新提示。
3. 后续如果用户反馈需要，再在 Settings 增加“自动检查更新”开关，并读取 / 写入 Sparkle updater 配置。

原因：Starcat 设置页已经有较多业务设置，自动更新不是核心使用流；首版保持原生菜单入口更克制。

---

## 5. 发版流程设计

### 5.1 Direct release 产物

Direct 发版产物至少包括：

```text
dist/
  Starcat-<version>.dmg
  appcast.xml
  Starcat-<version>.html 或 Starcat-<version>.md
  delta updates（由 generate_appcast 生成）
```

Sparkle 支持从 DMG / ZIP / tar 等格式更新。Starcat 官网分发已经倾向 DMG，因此 Direct 自动更新继续复用 notarized DMG，降低产物数量。

### 5.2 release.sh 扩展方向

现有流程：

```text
tag -> build-dmg.sh -> push tag -> GitHub Release
```

Direct 自动更新后建议扩展为：

```text
tag
  -> build Direct archive
  -> export Developer ID app
  -> notarize
  -> build DMG
  -> generate_appcast <updates_folder>
  -> upload DMG + appcast + release notes
  -> push tag / create GitHub Release
```

建议新增命令：

```bash
./scripts/release-direct.sh v0.1.1
./scripts/release-direct.sh v0.1.1 --dry-run
./scripts/release-direct.sh v0.1.1 --skip-upload
```

不要把 App Store release 和 Direct release 强行塞进同一条脚本主路径。两个渠道后续的签名、notarization、上传、Connect 流程不同，脚本可以共享底层函数，但入口应分开。

### 5.3 appcast 目录

建议维护一个固定 updates folder：

```text
releases/sparkle/
  Starcat-0.1.0.dmg
  Starcat-0.1.0.md
  Starcat-0.1.1.dmg
  Starcat-0.1.1.md
  appcast.xml
```

`generate_appcast` 每次扫描该目录，自动生成 appcast 和 delta updates。

### 5.4 Release notes

Starcat 已有 `CHANGELOG.md` / `CHANGELOG-ZH.md`。Direct 首版建议：

1. appcast release notes 先使用英文 Markdown。
2. 官网页面可以继续提供中英文更新日志。
3. 如果后续需要 Sparkle 窗口多语言 release notes，再评估是否按 Sparkle appcast 扩展字段做多语言。

---

## 6. 验证清单

### 6.1 App Store build 验证

每次提交 App Store archive 前检查：

```bash
otool -L Starcat.app/Contents/MacOS/Starcat | rg Sparkle
find Starcat.app -iname '*Sparkle*'
plutil -p Starcat.app/Contents/Info.plist | rg 'SUFeedURL|SUPublicEDKey|SUEnable'
strings Starcat.app/Contents/MacOS/Starcat | rg 'appcast|Check for Updates|Sparkle'
```

预期：全部无命中。

### 6.2 Direct build 验证

Direct 发版前检查：

1. `Sparkle.framework` 已打包并签名。
2. `Info.plist` 包含 `SUFeedURL` / `SUPublicEDKey` / `SUEnableInstallerLauncherService`。
3. entitlements 包含 Sparkle installer mach lookup temporary exception。
4. DMG 已 Developer ID 签名并 notarize。
5. appcast 可通过 HTTPS 访问。
6. 旧版本 Direct app 可以手动检查到新版本。
7. 更新包签名错误时 Sparkle 会拒绝更新。
8. 用户从 DMG 只读挂载路径运行时，不把不可更新状态伪装成成功。

### 6.3 单测策略

首版不需要用单测覆盖 Sparkle 自身行为。应覆盖 Starcat 自己的渠道判断：

1. `DistributionChannel` 从 Info.plist 正确读取。
2. App Store channel 不创建 Direct update controller。
3. Direct channel 才暴露更新命令。

注意：不要在 test host 启动期触发 Sparkle updater、Keychain 或系统授权弹窗。测试环境继续遵守 `TestEnvironment.isRunning` 门控。

---

## 7. 风险与约束

| 风险 | 影响 | 处理 |
|------|------|------|
| Sparkle 被误打进 App Store build | 审核风险高 | 用 target 分离，而不是运行时隐藏 |
| EdDSA private key 丢失 | 后续更新签名困难 | Keychain + 离线备份；密钥轮换只在必要时做 |
| appcast 被篡改 | 用户可能看到伪造更新信息 | HTTPS + EdDSA + signed feed |
| Developer ID / Notarization 流程不稳定 | 用户下载后 Gatekeeper 拦截 | Direct release 脚本必须把 notarization 作为硬门槛 |
| 从 DMG 中直接运行 app | Sparkle 无法正常替换 app | DMG 放 `/Applications` symlink，并在文档/安装页提示拖入 Applications |
| Direct 与 App Store bundle id 是否相同未定 | 影响数据共享与并存 | 实施前由 dong4j 拍板 |

---

## 8. 分阶段实施计划

### Phase 0：方案确认

- [ ] 确认 App Store build 完全不包含 Sparkle。
- [ ] 确认 Direct target / scheme 拆分策略。
- [ ] 确认 Direct bundle id 是否与 App Store 相同。
- [ ] 确认 appcast URL：`https://starcat.ink/appcast.xml` 或其他 CDN / GitHub Releases 地址。

### Phase 1：工程接入

- [ ] `project.yml` 增加 Sparkle SPM 依赖。
- [ ] 新增 Direct target / scheme。
- [ ] Direct build 注入 Sparkle Info.plist keys。
- [ ] Direct entitlements 增加 Sparkle installer mach lookup temporary exception。
- [ ] 新增 `DirectUpdateController` 和 Direct-only 更新菜单。
- [ ] About 开源致谢登记 Sparkle MIT License。

### Phase 2：发版脚本

- [ ] 新增或扩展 Direct build / notarize / DMG 脚本。
- [ ] 接入 `generate_appcast`。
- [ ] 生成并上传 appcast、DMG、release notes。
- [ ] 增加 App Store / Direct 产物自检命令。

### Phase 3：端到端验证

- [ ] 用旧版本 Direct app 检查并安装新版本。
- [ ] 验证签名失败、appcast 不可达、网络失败等错误路径。
- [ ] 验证 App Store archive 不含 Sparkle。
- [ ] 更新 `docs/6-发版与上架/SOP-发版流程.md` 的 Direct release 章节。

---

## 9. 待 dong4j 决策

| ID | 问题 | 推荐 |
|----|------|------|
| D-1 | Direct build 是否拆独立 target / scheme | 拆，审核边界最清楚 |
| D-2 | Direct bundle id 是否与 App Store 相同 | 首版可同 id；若要双版本并存则拆 `com.starcat.app.direct` |
| D-3 | appcast 托管在哪里 | 首选 `https://starcat.ink/appcast.xml`，官网域名更稳定 |
| D-4 | 首版是否做设置页自动更新开关 | 不做，先用菜单 + Sparkle 默认行为 |
| D-5 | 是否启用 signed feed | 启用，提高 appcast 与 release notes 安全性 |

---

## 10. 参考资料

- Sparkle 官方文档：`https://sparkle-project.org/documentation/`
- Sparkle sandboxing：`https://sparkle-project.org/documentation/sandboxing/`
- Sparkle Swift Package Index：`https://swiftpackageindex.com/sparkle-project/Sparkle`
- Apple App Review Guidelines：`https://developer.apple.com/app-store/review/guidelines/`

---

*维护者：dong4j + AI 协作者。后续 Sparkle 实施以本文为 Direct 自动更新的方案源；与 StoreKit 文档冲突时，App Store 渠道以 `StoreKit订阅上架方案.md` 为准，Direct 自动更新以本文为准。*
