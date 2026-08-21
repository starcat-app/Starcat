# SOP-App-Store-首次上架流程

> 创建：2026-07-08
> 适用：Starcat 第一次提交 Mac App Store / TestFlight。
> 目标：把「本地打包」到「App Store Connect 提交审核」完整串起来，避免第一次上架时在 Apple 后台和 Xcode 之间来回找入口。
> 当前 App Store 渠道：`Starcat` scheme，Bundle ID = `com.starcat.app.store`，支付 = StoreKit / Apple IAP。

---

## 0. 先读结论

第一次上架分 8 段：

1. **确认渠道边界**：App Store 版只走 StoreKit，不出现 Direct 授权码、Creem、Sparkle、外部支付。
2. **准备 Apple 后台**：证书、Bundle ID、App Store Connect App 记录、协议税务银行信息。
3. **准备商店物料**：截图、描述、隐私政策、支持页、审核备注、年龄分级、隐私标签。
4. **准备 IAP / 订阅**：月订 / 年订，商品 ID 与客户端一致。
5. **本地 archive**：运行 `scripts/package-appstore.sh` 生成 `Starcat-AppStore.xcarchive`。
6. **上传 build**：用 Xcode Organizer Validate / Distribute 到 App Store Connect。
7. **TestFlight 测试**：先内部测试，再按需外部测试，确认 GitHub 登录、Pro 购买、恢复购买、AI 门控。
8. **提交审核并发布**：选择 build，填写 Review Notes，提交审核，通过后手动或自动发布。

这份文档讲完整流程；命令级 archive 细节见 `docs/6-发版与上架/App Store 打包教程.md`。

---

## 1. 关联文档

| 文档 | 什么时候看 |
|------|------------|
| `docs/6-发版与上架/SOP-双渠道签名与发布.md` | 理解 App Store / Direct 两套产物、签名、支付边界 |
| `docs/6-发版与上架/App Store 打包教程.md` | 本地生成 `.xcarchive` 与上传的简版命令 |
| `docs/6-发版与上架/v1-上架检查清单.md` | 上架前 P0/P1 检查项总表 |
| `docs/6-发版与上架/v1-上架信息准备.md` | App Store Connect 字段、描述、权限、审核备注事实来源 |
| `docs/6-发版与上架/SOP-App-Store-Connect-Offer-Code.md` | Offer Code / 订阅优惠码配置 |
| `docs/2-产品/需求讨论/正式方案/支付对接正式方案.md` | StoreKit 与 Direct 支付边界、统一 Pro 权益方案 |
| `docs/2-产品/需求讨论/正式方案/Pro付费墙验证清单.md` | Pro 门控、购买、恢复购买人工验收 |

Apple 官方入口：

- [Create an app record / Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [Overview of submitting for review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/overview-of-submitting-for-review/)
- [App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)
- [Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [Enter server URLs for App Store Server Notifications](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/enter-server-urls-for-app-store-server-notifications/)

---

## 2. Starcat App Store 渠道边界

提交 App Store 前先确认下面这些边界没有混：

| 项 | App Store 版 |
|----|-------------|
| Scheme | `Starcat` |
| Bundle ID | `com.starcat.app.store` |
| Distribution | `STARCAT_DISTRIBUTION=appstore` |
| 签名 | `Apple Distribution` |
| 支付 | StoreKit / Apple IAP |
| Pro 解锁 | Apple transaction / subscription |
| 更新 | App Store |
| 不应出现 | Direct 授权码、Creem / Waffo / 外部 checkout、Sparkle 更新、官网购买链接 |

本地可用下面命令快速确认工程设置：

```bash
xcodegen generate

xcodebuild -scheme Starcat -configuration Release -showBuildSettings \
  | rg "PRODUCT_BUNDLE_IDENTIFIER|STARCAT_DISTRIBUTION|DEVELOPMENT_TEAM"
```

期望：

```text
PRODUCT_BUNDLE_IDENTIFIER = com.starcat.app.store
STARCAT_DISTRIBUTION = appstore
DEVELOPMENT_TEAM = 8WCUMGCWMB
```

如果看到 `StarcatDirect`、`com.starcat.app.direct`、`direct`、Sparkle 或外部授权码，说明你走错渠道，先停下来排查。

---

## 3. Apple 后台一次性准备

### 3.1 协议 / 税务 / 银行

App Store Connect 左侧或顶部会提示 **Agreements, Tax, and Banking**。第一次上架前必须确认：

- Apple Developer Program 已生效。
- Paid Apps Agreement 已同意。
- 税务信息已提交。
- 银行账户已提交。
- 如果只上免费 App 也建议把协议补齐，因为 Starcat 有订阅 IAP。

没有处理完这些，App 可以创建记录，但订阅、销售和收款会卡住。

### 3.2 Certificates / Identifiers

进入 Apple Developer Account：

1. **Certificates**：确认本机 Keychain 有 `Apple Distribution`。
2. **Identifiers**：确认存在 App ID / Bundle ID：

```text
com.starcat.app.store
```

3. Capabilities 至少要和 App Store 包一致：
   - App Sandbox
   - Network Client
   - Network Server（MCP loopback，本机 `127.0.0.1`，默认关闭）
   - User Selected File Read/Write
   - In-App Purchase

当前 Starcat 证书和双渠道说明见 `docs/6-发版与上架/SOP-双渠道签名与发布.md`。

### 3.3 Xcode 账号

本机 Xcode：

1. Xcode -> Settings -> Accounts。
2. 登录 Apple Developer 账号。
3. 选择 Team。
4. 点 `Download Manual Profiles`。

当前 Team ID：

```text
8WCUMGCWMB
```

---

## 4. App Store Connect 新建 App

进入 [App Store Connect](https://appstoreconnect.apple.com)：

1. **我的 App** -> `+` -> **新 App**。
2. 平台选择 **macOS**。
3. 填字段：

| 字段 | Starcat 建议值 | 说明 |
|------|----------------|------|
| Name | `Starcat` | 用户可见 App 名 |
| Primary Language | `English (U.S.)` | 当前 `v1-上架信息准备.md` 主语言按英文准备 |
| Bundle ID | `com.starcat.app.store` | 必须选 App Store 版 Bundle ID |
| SKU | `starcat-macos-store` | 内部用，创建后通常不重要，但建议稳定可读 |
| User Access | Full Access | 个人账号通常无复杂权限 |

创建后不要急着提交，先补完整 App 信息、定价、隐私和订阅。

---

## 5. App Store 页面字段

字段事实来源优先看 `docs/6-发版与上架/v1-上架信息准备.md`。

### 5.1 App Information

建议：

| 字段 | 值 |
|------|----|
| Category | `Developer Tools` |
| Secondary Category | `Productivity` |
| Content Rights | Starcat 自有代码 + 已登记开源依赖；开源致谢在 About 页 |
| Age Rating | 通常 `4+`，按后台问卷逐项回答 |

注意：

- 不要把 Starcat 描述成通用账号系统。它是 GitHub Stars 专用客户端。
- 如果 Apple 问 Sign in with Apple，审核备注里说明 Starcat 是 GitHub 专用工具，GitHub 登录是访问用户 Stars 的必要能力。

### 5.2 Pricing and Availability

Starcat App 本体建议设为：

```text
Free
```

Pro 收费通过自动续期订阅完成，不要把 App 本体设为付费下载。

### 5.3 App Privacy

按真实行为填写。Starcat 需要重点披露：

- GitHub OAuth 用于读取用户 GitHub Stars。
- GitHub token / AI Provider key 保存在本机 Keychain。
- Stars、标签、笔记、状态、本地搜索缓存保存在本机。
- AI 请求只在用户触发相关功能时发送到配置的 Provider 或 Starcat 服务。
- Aptabase / 诊断如果启用，按 `v1-上架信息准备.md` 的隐私章节填写。

不要为了“看起来少收集”而少填。审核时隐私标签和 App 行为不一致，风险比多披露更大。

### 5.4 App Review Information

Review Notes 建议至少写清：

```text
Starcat is a GitHub Stars manager for macOS.

GitHub login is required because the app's core purpose is to sync and organize the user's GitHub Stars. The app is not a general account system.

The MCP service is optional, off by default, listens on 127.0.0.1 only, and requires a local bearer token.

Pro subscription in this App Store build is handled through Apple In-App Purchase. Direct distribution, website checkout, and standalone license activation are separate from this App Store submission.

Pro features can be tested through StoreKit/TestFlight subscription flow. AI provider keys are stored locally in Keychain.
```

如果能提供测试 GitHub 账号，写在后台的测试账号字段里；如果不能提供，明确说明需要审核员用自己的 GitHub 账号登录才能看到 Stars。

### 5.5 Screenshots

macOS 截图至少准备 5 张，避免只截登录页：

1. 主窗口三栏：Stars 列表 + Sidebar + Detail。
2. README / 仓库详情。
3. AI 摘要 / AI Chat / README 翻译。
4. 智能集合。
5. Activity / Trending / Weekly / Release 追踪。

素材和文案候选见 `docs/6-发版与上架/v1-上架信息准备.md` §1.4 与 §2.3。

截图注意：

- 不要露出真实私密 token、邮箱、API key。
- 尽量使用公开仓库和可公开账号。
- 截图展示的功能必须在 App Store build 里真实可用。
- App Store 版截图不要出现官网购买、Creem、License Key、Sparkle 更新。

---

## 6. 订阅 / IAP

Starcat App Store 版只走 StoreKit，Direct 的 Creem / License API 不进入 App Store build。

### 6.1 商品 ID

以代码和现有 StoreKit 配置为准，当前文档中已有这些 Product ID：

```text
com.starcat.app.pro.monthly
com.starcat.app.pro.yearly
```

创建订阅时必须保持一致。Product ID 创建后不建议改名，改名会导致客户端拉不到商品。

### 6.2 创建订阅组

App Store Connect：

1. **Monetization** / **Subscriptions**。
2. 创建 Subscription Group：`Starcat Pro`。
3. 创建月订：`Starcat Pro Monthly`。
4. 创建年订：`Starcat Pro Yearly`。
5. 添加本地化名称、描述、价格、可用地区。

### 6.3 App Store Server Notifications

首版如果客户端只靠 StoreKit 2 刷新权益，可以暂时不接服务端通知；但后续如果你要做服务端订阅状态、退款、账单宽限期分析，应该配置 App Store Server Notifications。

如果配置，后台填服务端 HTTPS URL，不能填本地地址。相关官方入口见 Apple 文档：`Enter server URLs for App Store Server Notifications`。

### 6.4 IAP 与 App 一起提交

第一次提交带订阅的 App 时，经常漏掉这一步：

- App version 提交审核时，要把新建的订阅商品也加入本次提交。
- 如果订阅状态还不是可审核状态，App 审核可能因为购买项不可用被卡住。
- TestFlight 能看到商品，不代表正式审核一定已经把 IAP 关联进提交。

Offer Code 另见 `docs/6-发版与上架/SOP-App-Store-Connect-Offer-Code.md`。

### 6.5 什么时候配置订阅商品

订阅商品**不用等 App 正式上架后再配置**。正确顺序是：

1. 先在 App Store Connect 创建 Starcat App 记录，Bundle ID 选择 `com.starcat.app.store`。
2. 立刻创建订阅组和订阅商品。
3. 配好月订 / 年订价格、地区、本地化。
4. 上传 build 后，在提交 App Review 前把订阅商品和 App version 一起加入本次提交。
5. TestFlight 阶段就用这些 Connect 商品做真实 Sandbox / TestFlight 购买验证。

如果等 App 上架后才配置订阅，会导致首版审核时 Pro 购买不可测，付费墙显示“订阅商品暂不可用”，也容易被审核认为订阅功能没有准备好。

### 6.7 “订阅商品暂不可用”排查

Starcat 付费墙出现“订阅商品暂不可用”时，先判断当前运行环境。

#### 本地 Debug / Xcode Run

本地开发不依赖 App Store Connect 商品，应该走本地 StoreKit 配置：

1. Xcode -> Scheme `Starcat` -> Edit Scheme -> Run -> Options。
2. StoreKit Configuration 选择：

```text
Starcat/Resources/Products.storekit
```

3. 重新运行 App。
4. 打开付费墙，确认能看到月订 / 年订商品。

如果这里仍不可用，检查 `Products.storekit` 中的 Product ID 是否与代码一致：

```text
com.starcat.app.pro.monthly
com.starcat.app.pro.yearly
```

#### TestFlight / 生产包

TestFlight 和生产包必须走 App Store Connect，不能挂本地 `.storekit`：

1. Scheme 的 StoreKit Configuration 必须是 **None**。
2. App Store Connect 已创建订阅组和订阅商品。
3. Product ID 与客户端一致。
4. 订阅商品已配置价格、地区、本地化。
5. Paid Apps Agreement / Tax / Banking 没有阻塞销售能力。
6. 上传的 build 属于 `com.starcat.app.store`，不是 Direct build。
7. 如果是第一次提交，订阅商品要和 App version 一起加入审核。

排查顺序建议：

```bash
xcodebuild -scheme Starcat -configuration Release -showBuildSettings \
  | rg "PRODUCT_BUNDLE_IDENTIFIER|STARCAT_DISTRIBUTION"
```

期望：

```text
PRODUCT_BUNDLE_IDENTIFIER = com.starcat.app.store
STARCAT_DISTRIBUTION = appstore
```

如果 Bundle ID 或 distribution 不对，先修构建渠道；如果构建渠道正确，再回 App Store Connect 检查订阅商品状态。

---

## 7. 本地发版前检查

### 7.1 工作区和版本

```bash
git status
git log --oneline -5
```

正式 archive 前建议工作区干净。版本号机制见 `docs/6-发版与上架/SOP-发版流程.md`。

### 7.2 同步 Xcode 工程

```bash
xcodegen generate
```

新增 / 删除 Swift 文件后必须跑，否则 Xcode project 可能不是最新。

### 7.3 跑测试

关闭 Xcode IDE 后运行：

```bash
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test
```

如果只做文档或后台配置，可不跑全量测试；提交正式 build 前建议跑。

### 7.4 生成 App Store archive

推荐：

```bash
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB \
./scripts/package-appstore.sh
```

产物：

```text
dist/appstore/Starcat-AppStore.xcarchive
dist/appstore/xcodebuild-appstore.log
```

只在本机导出最终 Distribution 签名的 `.pkg`、暂不上传时：

```bash
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB \
STARCAT_APPSTORE_EXPORT=1 \
STARCAT_APPSTORE_ALLOW_PROVISIONING_UPDATES=1 \
STARCAT_APPSTORE_SKIP_OPEN=1 \
./scripts/package-appstore.sh
```

额外产物为 `dist/appstore/export/Starcat.pkg` 和
`dist/appstore/xcodebuild-appstore-export.log`。Automatic Signing 的 archive 可以使用开发
签名；最终签名门禁以本地 export 解包后的主 App、Widget、`codebase.bin` 和 Store profile 为准。

脚本会检查：

- scheme 是 `Starcat`。
- `STARCAT_DISTRIBUTION=appstore`。
- Bundle ID 是 `com.starcat.app.store`。
- App Store 包不包含 Sparkle。
- App Store 包包含 sandbox entitlement。

失败先看日志：

```bash
tail -120 dist/appstore/xcodebuild-appstore.log
```

---

## 8. 上传 build

### 8.1 Xcode Organizer 上传

第一次建议用 Xcode Organizer，不建议一开始就自动化上传：

1. 打开 Xcode。
2. Window -> Organizer。
3. 选择 `Starcat-AppStore.xcarchive`。
4. 点 **Validate App**。
5. Validate 通过后点 **Distribute App**。
6. 选择 **App Store Connect**。
7. 选择 **Upload**。
8. 按 Xcode 向导继续，保持自动签名或确认 Team 为 `8WCUMGCWMB`。
9. 上传完成后回到 App Store Connect 等 Processing。

### 8.2 Processing 状态

上传后 build 不会立刻出现在版本页。常见状态：

| 状态 | 含义 |
|------|------|
| Uploaded / Processing | Apple 正在处理二进制 |
| Missing Compliance | 需要补 Export Compliance |
| Invalid Binary | Apple 处理失败，看邮件和 Activity 详情 |
| Ready to Submit | 可以选中提交审核 |

如果 30-60 分钟还没出现，先看 App Store Connect 邮件和 Build 页面，不要反复上传同一个 build 号。

### 8.3 Build 号重复

同一个 App Store 版本下，build 号必须递增。Starcat 的 `CFBundleVersion` 由 commit count 驱动；如果你重复上传同一个 commit，可能遇到 build 号重复。

处理方式：

1. 正常做一个新 commit 后重新 archive。
2. 不要手改 `Info.plist` 产物绕过，保持 `scripts/bump-version.sh` 作为来源。

---

## 9. TestFlight

### 9.1 内部测试

上传 build 处理完成后：

1. App Store Connect -> Starcat -> TestFlight。
2. 选择 build。
3. 填 Beta App Review Information。
4. 添加 Internal Testers。
5. 等测试员收到邀请。

内部测试通常不需要完整外部审核，但仍可能要求 export compliance。

### 9.2 外部测试

如果要找外部用户测试：

1. 创建 External Group。
2. 添加测试说明。
3. 提交 Beta App Review。
4. Apple 通过后邀请外部测试员。

第一次上架建议至少自己和 1-2 个外部设备走一遍，不要直接把第一个 build 提交正式审核。

### 9.3 TestFlight 验收清单

| 场景 | 必测 |
|------|------|
| GitHub OAuth 登录 | [ ] |
| Stars 全量同步 / 增量同步 | [ ] |
| 搜索 / README / 标签 / 笔记 / 状态 | [ ] |
| Trending / Weekly / Activity | [ ] |
| Pro 月订购买 | [ ] |
| Pro 购买后立即解锁 | [ ] |
| 恢复购买 | [ ] |
| 取消订阅后权益变化 | [ ] |
| AI Provider 配置 / AI 摘要 | [ ] |
| App 重启后 Pro 状态恢复 | [ ] |
| App Store 包内无 License Key / Creem / Sparkle 入口 | [ ] |

IAP 在 TestFlight / Sandbox 环境不会真实扣正式费用，但仍要用 Sandbox / TestFlight 账户完整走购买流程。

---

## 10. 提交 App Review

### 10.1 版本页准备

App Store Connect -> Starcat -> App Store -> macOS App -> 当前版本：

1. 选择已处理完成的 build。
2. 填截图。
3. 填描述、关键词、Support URL、Privacy URL。
4. 填年龄分级。
5. 填 App Review Information。
6. 填 Export Compliance。
7. 确认 IAP / subscriptions 已关联提交。
8. 保存。

### 10.2 Export Compliance

Starcat 使用系统 HTTPS / TLS、GitHub API、AI Provider API，不自行实现加密算法。通常按 Apple 后台问卷如实回答即可。

如果后台要求说明，建议口径：

```text
The app uses standard Apple platform networking APIs and HTTPS/TLS for communication with GitHub, Starcat services, and user-configured AI providers. It does not implement proprietary encryption algorithms.
```

### 10.3 Review Notes 模板

建议在 App Review Notes 中写：

> Starcat 1.1.x 的 RAG 数据流、App Privacy 和审核步骤必须同时参考 [`v1.1-RAG隐私与审核备注.md`](v1.1-RAG隐私与审核备注.md)，下面的通用模板不能替代 RAG 专项披露。

```text
Starcat is a native macOS client for organizing GitHub Stars.

GitHub login is required because the core feature is syncing the user's GitHub Stars. This is not a general account system.

Pro subscription in this App Store build is handled through Apple In-App Purchase. Direct distribution, website checkout, and standalone license activation are separate from this App Store submission.

Pro features are unlocked through StoreKit subscriptions immediately upon purchase.

The optional MCP service is off by default, listens only on 127.0.0.1, and requires a local bearer token. It is intended for local developer tools on the same Mac.

AI features require Pro and either a user-configured provider key or Starcat service. User provider keys are stored locally in Keychain.
```

如果有测试账号：

```text
GitHub test account:
Username: <review-test-account>
Password: <provided in App Store Connect secure fields>
```

如果没有测试账号：

```text
Reviewers may use their own GitHub account to test syncing Stars. The app requests GitHub access only to read and manage the user's Stars.
```

### 10.4 提交

确认无误后点 **Add for Review** / **Submit for Review**。

提交后常见状态：

| 状态 | 含义 |
|------|------|
| Waiting for Review | 排队中 |
| In Review | 审核中 |
| Rejected | 被拒，需要看 Resolution Center |
| Metadata Rejected | 通常是截图、描述、隐私、审核备注问题 |
| Pending Developer Release | 审核通过，等待你手动发布 |
| Ready for Distribution | 已可上架或可发布 |

---

## 11. 通过审核后的发布

### 11.1 发布方式

首次建议选择 **Manual Release**，不要审核通过后自动上架。原因：

- 可以先确认订阅商品状态。
- 可以检查页面、截图、价格、地区。
- 可以准备官网 / 发布日志 / 支持页面。

### 11.2 发布前最后检查

| 项 | 检查 |
|----|------|
| App 页面 | 截图、描述、Support URL、Privacy URL 正确 |
| IAP | 月订 / 年订 / 试用状态可用 |
| Build | 选中的是最终 build |
| 价格 | App 免费，Pro 订阅价格正确 |
| 地区 | 可用地区符合预期 |
| 官网 | `https://dong4j.app/starcat` 页面没有引导 App Store 用户走外部支付 |
| 客服邮箱 | `dong4j@gmail.com` 与页面一致 |

### 11.3 上线后检查

发布后：

1. 从 Mac App Store 搜索 Starcat。
2. 下载 App Store 版。
3. 确认 Bundle ID / 容器路径符合 App Store 版。
4. 登录 GitHub。
5. 测试 Pro 订阅 / 恢复购买。
6. 测试 AI 服务页不再显示错误的未开通状态。
7. 检查崩溃、反馈、App Store Connect Analytics。

---

## 12. 常见坑

### 12.1 Bundle ID 选错

症状：

- App Store Connect 选择不到 build。
- 上传报 bundle identifier mismatch。
- App Store 包里出现 Direct 行为。

修复：

```bash
xcodebuild -scheme Starcat -configuration Release -showBuildSettings \
  | rg "PRODUCT_BUNDLE_IDENTIFIER|STARCAT_DISTRIBUTION"
```

必须是：

```text
com.starcat.app.store
appstore
```

### 12.2 上传后 build 不出现

先等 Processing。然后检查：

- App Store Connect 邮件。
- TestFlight -> Builds。
- 是否 Missing Compliance。
- 是否 build 号重复。

### 12.3 IAP 拉不到商品

检查：

- Product ID 是否与客户端一致。
- 订阅商品是否已创建并处于可测试 / 可提交状态。
- Scheme 的 StoreKit Configuration：本地开发用 `.storekit`，TestFlight / 生产必须是 None。
- App version 提交时是否把 IAP 一起提交。

### 12.4 审核问为什么没有 Sign in with Apple

Starcat 的正确解释：

```text
Starcat is a dedicated GitHub client. GitHub login is required to access the user's GitHub Stars, which are the primary content managed by the app. The app does not provide a general account system.
```

### 12.5 审核发现外部支付

App Store build 不允许出现外部 checkout、官网购买、授权码激活。检查：

- 设置 -> Pro 页面。
- 付费墙。
- AI 服务页。
- 官网链接。
- About / Support 链接。

如果出现 Direct 文案，回到 `DistributionChannel` / `STARCAT_DISTRIBUTION` 排查。

### 12.6 Support / Privacy URL 不可访问

提交前手动打开：

```text
https://dong4j.app/starcat
https://dong4j.app/starcat/support
https://dong4j.app/starcat/privacy
https://dong4j.app/starcat/eula
```

任一 404 / 证书错误 / 内容不一致，都先修官网再提交审核。

---

## 13. 首次上架最小执行清单

### 13.1 后台

- [ ] Apple Developer Program 生效。
- [ ] Paid Apps Agreement / Tax / Banking 完成。
- [ ] Bundle ID `com.starcat.app.store` 存在。
- [ ] App Store Connect 创建 Starcat macOS App。
- [ ] App 本体定价为 Free。
- [ ] 月订 / 年订商品创建完成。
- [ ] 14 天 Introductory Offer 配置完成。
- [ ] App Privacy 填写完成。
- [ ] Age Rating 填写完成。
- [ ] Support / Privacy / EULA URL 可访问。

### 13.2 本地

- [ ] `xcodegen generate`
- [ ] `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test`
- [ ] `STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB ./scripts/package-appstore.sh`
- [ ] Xcode Organizer Validate App 通过。
- [ ] Xcode Organizer Distribute App 上传成功。

### 13.3 TestFlight

- [ ] Build 处理完成。
- [ ] 内部测试安装成功。
- [ ] GitHub 登录和同步通过。
- [ ] Pro 订阅 / 试用 / 恢复购买通过。
- [ ] AI Pro 门控通过。
- [ ] App Store 包没有 Direct 支付 / 授权码 / Sparkle 入口。

### 13.4 提交审核

- [ ] 选择最终 build。
- [ ] 截图 5 张以上。
- [ ] 描述、关键词、分类、价格确认。
- [ ] Review Notes 填写 GitHub 登录、MCP、IAP、AI 数据说明。
- [ ] IAP 与 App 一起提交。
- [ ] Export Compliance 填写完成。
- [ ] 选择 Manual Release。
- [ ] Submit for Review。

---

## 14. 变更日志

| 日期 | 变更 |
|------|------|
| 2026-07-08 | 初版：补齐 Starcat 首次 Mac App Store 上架全流程 |
