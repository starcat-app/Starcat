# App Store 首次上架实战记录

> 创建：2026-07-10
> 适用：Starcat 第一次提交 Mac App Store / TestFlight 时的后台配置复盘。
> 定位：这不是替代 SOP 的命令清单，而是把第一次上架过程中遇到的 App Store Connect、TestFlight、IAP、税务、银行、DSA、ICP备案等实际问题沉淀下来。

---

## 1. 结论先行

Starcat App Store 版本按下面边界处理：

| 项 | 当前结论 |
|----|----------|
| App Store Bundle ID | `com.starcat.app.store` |
| App 本体价格 | 免费下载 |
| Pro 月订阅 | `com.starcat.app.pro.monthly` |
| Pro 年订阅 | `com.starcat.app.pro.yearly` |
| Pro 终身版 | `com.starcat.app.pro.lifetime`，非消耗型项目 |
| TestFlight 商品来源 | App Store Connect sandbox，不读本地 `Products.storekit` |
| Direct 支付 | 不出现在 App Store 版中 |
| 中国大陆首发 | 备案未完成前，先排除中国大陆销售范围 |
| 欧盟 DSA | 如果保留欧盟销售范围，需要补交易商合规信息 |

首发推荐顺序：

1. App Store 版先排除中国大陆。
2. App 本体设为免费。
3. 三个 IAP / 订阅都挂到 `1.0.0 (1271)` 版本。
4. Paid Apps Agreement、税务、银行完成后再验证 TestFlight 订阅拉取。
5. 中国大陆备案、DSA、国内收款信息不要阻塞海外首发。

---

## 2. 关联文档

| 文档 | 用途 |
|------|------|
| `docs/6-发版与上架/SOP-App-Store-首次上架流程.md` | 正式流程 SOP |
| `docs/6-发版与上架/SOP-手动发布命令清单.md` | 只放手动发布命令 |
| `docs/6-发版与上架/App Store 打包教程.md` | App Store archive 打包 |
| `docs/6-发版与上架/SOP-双渠道签名与发布.md` | App Store / Direct 双渠道边界 |
| `docs/6-发版与上架/App-Store-合规域名隔离改造.md` | App Store 专用域名和 Direct 域名隔离 |
| `docs/6-发版与上架/v1-上架信息准备.md` | App Store Connect 字段准备 |

---

## 3. Apple Developer / Bundle ID / Capabilities

### 3.1 Bundle ID

App Store 版使用独立 Bundle ID：

```text
com.starcat.app.store
```

创建 App ID 时选择 Explicit Bundle ID。

![Register an App ID](assets/app-store-first-submit/03-register-app-id.png)

### 3.2 Capabilities

必须启用的是 `In-App Purchase`。截图里 `In-App Purchase` 是正确项，`StoreKit External Purchases or Offers` 不是 Starcat App Store 版当前要用的能力。

![In-App Purchase capability](assets/app-store-first-submit/04-capability-in-app-purchase.png)

![External purchases capability](assets/app-store-first-submit/05-capability-external-purchases.png)

能力请求里的 Web Browser Engine、JIT、Window Follow 等不需要。

![Capability requests](assets/app-store-first-submit/06-capability-requests.png)

---

## 4. App Store Connect 基础信息

### 4.1 App 名称 / 副标题 / SKU

App 名称最终使用：

```text
Starcat for GitHub
```

副标题建议控制在 30 字符内，强调用途，不写“macOS 原生”这类废话。可用：

```text
Organize GitHub Stars
```

SKU 是内部字段，可以用：

```text
starcat-macos-store
```

![Localized subtitle](assets/app-store-first-submit/11-localized-subtitle.png)

### 4.2 技术支持网址 / 营销网址

App Store 版不要用含 Direct 下载、Creem、license、Sparkle 的页面作为审核入口。

推荐：

```text
技术支持网址: https://dong4j.app/starcat/support
营销网址: https://dong4j.app/starcat
隐私政策: https://dong4j.app/starcat/privacy
```

如果这些页面还没正式准备好，不要用 `starcat.ink` 的 Direct 落地页硬顶。

![Support and marketing URL](assets/app-store-first-submit/09-support-marketing-url.png)

### 4.3 内容版权

如果 App 不包含、显示或访问第三方内容，可以选“不包含第三方内容”。如果认为 GitHub README、仓库元数据属于第三方内容，则选“是”并确保有访问这些内容的合理权限。

Starcat 的实际风险点是 GitHub 内容展示。保守处理时，选择“是”更稳。

![Content rights](assets/app-store-first-submit/12-content-rights.png)

### 4.4 许可协议

默认使用 Apple 标准 EULA 即可。第一次上架不需要自定义 EULA，除非后续要加入特殊条款。

![EULA](assets/app-store-first-submit/13-eula.png)

### 4.5 App 审核信息

如果审核需要登录，提供可用 GitHub 测试账号；如果不能提供，审核备注里说明 Starcat 是 GitHub Stars 管理工具，GitHub 登录是核心功能必需。

![App review information](assets/app-store-first-submit/08-app-review-info.png)

---

## 5. App 隐私

Starcat 使用 Aptabase，因此 App Privacy 里需要按真实用途填写。不要为了少披露而漏填。

当前可归类的数据类型包括：

- 产品交互：Aptabase 事件，用于分析功能使用情况。
- 崩溃数据：如果收集崩溃诊断。
- 性能数据：如果收集启动、请求、耗时类性能指标。
- 其他诊断数据：日志、错误类型等。

产品交互用途选择 `分析`，如果用于 App 功能保障，也可选 `App 功能`。不要选择广告相关用途。

![App privacy overview](assets/app-store-first-submit/15-app-privacy.png)

![Privacy product interaction](assets/app-store-first-submit/16-privacy-product-interaction.png)

---

## 6. App 预览、截图和审核截图

App Store 页面截图要求 macOS 尺寸，例如：

```text
1280 x 800
1440 x 900
2560 x 1600
2880 x 1800
```

“App 预览”是视频，可以不填；截图必须填。

![App previews and screenshots](assets/app-store-first-submit/10-app-previews-screenshots.png)

IAP / 订阅审核截图可以截 Pro 页面，重点展示商品和购买入口。

![IAP review screenshot field](assets/app-store-first-submit/18-iap-review-info.png)

![Review screenshot example](assets/app-store-first-submit/19-review-screenshot-example.png)

---

## 7. StoreKit 本地测试和 TestFlight 差异

### 7.1 本地 `Products.storekit`

Xcode 本地调试可以用 `Products.storekit`。正确配置后，本地 Pro 页面能显示商品。

![Xcode StoreKit config](assets/app-store-first-submit/20-xcode-storekit-config.png)

![StoreKit config options](assets/app-store-first-submit/22-storekit-config-options.png)

![Pro page products](assets/app-store-first-submit/23-pro-page-products.png)

如果 StoreKit Transactions 窗口为空，只表示本地还没有交易，不代表商品一定不可用。

![StoreKit transactions empty](assets/app-store-first-submit/21-storekit-transactions-empty.png)

### 7.2 TestFlight 不读本地 StoreKit 文件

TestFlight 里的商品来自 App Store Connect sandbox。商品没有补齐元数据、没有挂版本、Paid Apps Agreement 没有生效时，App 里可能显示“订阅商品不可用”。

![StoreKit unavailable](assets/app-store-first-submit/01-storekit-unavailable.png)

---

## 8. IAP / 订阅配置

### 8.1 产品 ID

Starcat 当前三种 Pro 商品：

| 商品 | 类型 | Product ID |
|------|------|------------|
| Monthly | 自动续期订阅 | `com.starcat.app.pro.monthly` |
| Yearly | 自动续期订阅 | `com.starcat.app.pro.yearly` |
| Lifetime | 非消耗型项目 | `com.starcat.app.pro.lifetime` |

Monthly / Yearly 在“订阅”下创建。Lifetime 在“App 内购买项目”下创建为非消耗型项目。

![Subscription group](assets/app-store-first-submit/17-subscription-group.png)

### 8.2 名称和描述

App Store Connect 的商品描述有字符限制。可用短描述：

```text
Starcat Pro Monthly
Unlock Starcat Pro monthly.
```

```text
Starcat Pro Yearly
Unlock Starcat Pro yearly.
```

```text
Starcat Pro Lifetime
Unlock all current Starcat Pro features.
```

中文本地化：

```text
Starcat Pro 月度版
按月解锁 Starcat Pro。
```

```text
Starcat Pro 年度版
按年解锁 Starcat Pro。
```

```text
Starcat Pro 终身版
解锁当前全部 Starcat Pro 功能。
```

### 8.3 审核备注

Monthly：

```text
This auto-renewable subscription unlocks Starcat Pro monthly. Open Preferences > Pro to view and purchase the monthly plan.
```

Yearly：

```text
This auto-renewable subscription unlocks Starcat Pro yearly. Open Preferences > Pro to view and purchase the yearly plan.
```

Lifetime：

```text
This non-consumable purchase unlocks Starcat Pro features. Open Preferences > Pro to view and purchase the lifetime plan.
```

![Monthly subscription detail](assets/app-store-first-submit/34-monthly-subscription-detail.png)

![Monthly review info](assets/app-store-first-submit/35-monthly-review-info.png)

### 8.4 元数据丢失

`元数据丢失` 通常不是代码问题，而是 App Store Connect 商品配置不完整。重点检查：

1. 商品本地化名称和描述。
2. 订阅组本地化名称。
3. 价格。
4. 销售范围。
5. 审核截图。
6. 审核备注。
7. 是否已经挂到 App 版本。

![IAP draft metadata missing](assets/app-store-first-submit/31-iap-draft-metadata-missing.png)

![Lifetime IAP detail top](assets/app-store-first-submit/32-lifetime-iap-detail-top.png)

![Lifetime IAP detail bottom](assets/app-store-first-submit/33-lifetime-iap-detail-bottom.png)

### 8.5 挂到版本

首次提交 IAP / 订阅时，需要把商品挂到 App 版本页面里的“App 内购买项目和订阅”区域。当前三个商品已经挂到 `1.0.0 (1271)`。

![Version linked IAPs](assets/app-store-first-submit/36-version-linked-iaps.png)

---

## 9. TestFlight 用户和沙盒测试账号

### 9.1 内部测试用户

App Store Connect 的“用户和访问”里添加的是团队用户，可用于内部 TestFlight 测试。可以添加另一个 Apple ID，但要让对方接受邀请。

建议权限只给 `App 管理` 或 `开发者`，并只授权 Starcat。

![Users and access](assets/app-store-first-submit/28-users-access.png)

### 9.2 沙盒测试账号

沙盒测试账号不需要真实可收邮件，但建议按场景命名：

```text
starcat.sandbox.monthly.001@dong4j.test
starcat.sandbox.yearly.001@dong4j.test
starcat.sandbox.lifetime.001@dong4j.test
```

![Sandbox tester](assets/app-store-first-submit/29-sandbox-tester.png)

### 9.3 TestFlight 审核

内部测试不需要 TestFlight Beta App Review。外部测试需要 TestFlight 审核。

如果不想等 TestFlight 外部审核，使用 Internal Testing 群组即可。

![TestFlight review waiting](assets/app-store-first-submit/27-testflight-review-waiting.png)

---

## 10. App Store Connect API Key

当前手动上传、手动配置，不需要创建 App Store Connect API Key。

这个 Key 主要用于：

- CI 自动上传 build。
- fastlane 自动提交审核。
- 服务端 App Store Server API 校验订阅。

当前阶段可以不点“请求访问”。

![App Store Connect API](assets/app-store-first-submit/30-app-store-connect-api.png)

---

## 11. App 本体价格和销售范围

Starcat App 本体应设为免费，Pro 通过 IAP / 订阅收费。

App 本体价格页必须添加定价：

```text
Free
```

否则会看到所有国家和地区未供应。

![App price and availability](assets/app-store-first-submit/43-app-price-availability.png)

注意：

- 不要在 App 本体价格里填 `$2.99` / `$19.99` / `$39.99`。
- 这些价格属于 Monthly / Yearly / Lifetime。
- 备案没下来前，App 本体和 IAP / 订阅销售范围都先排除中国大陆。

---

## 12. Paid Apps Agreement、税务和银行

### 12.1 Paid Apps Agreement

如果 `Paid Apps Agreement` 不是有效状态，StoreKit sandbox 可能拉不到商品。必须完成：

1. 付费 App 协议。
2. 税务表。
3. 银行账户。
4. 联系人信息。

![Paid Apps agreement](assets/app-store-first-submit/37-paid-apps-agreement.png)

### 12.2 W-8BEN / Title

个人开发者的 `Title` 可以填：

```text
Owner
```

如果不接受，再填：

```text
Individual Developer
```

![Tax title](assets/app-store-first-submit/38-tax-title.png)

![W-8BEN form](assets/app-store-first-submit/39-w8ben-form.png)

### 12.3 银行账户主体

银行账户持有人应与 Apple 开发者主体、税务主体一致。当前 Apple 主体是 `liwen gong`，因此银行账户也应使用 `liwen gong` 名下账户。

不建议混用其他人的银行卡，否则可能导致付款失败或合规问题。

![Bank account](assets/app-store-first-submit/40-bank-account.png)

### 12.4 CNAPS

中国大陆人民币收款需要具体开户支行的 CNAPS 联行号。不能填“工商银行通用 CNAPS”。应通过银行 App 或客服查询开户支行的 12 位联行号。

![CNAPS bank](assets/app-store-first-submit/42-cnaps-bank.png)

---

## 13. 欧盟 DSA

如果销售范围包含欧盟，需要处理 DSA 合规。

选择原则：

- 如果覆盖欧盟用户，并通过 App Store 销售 IAP / 订阅，倾向选择“我是 DSA 所定义的交易商”，然后提供公开联系信息。
- 如果暂时不覆盖欧盟，可选择“我不是 DSA 所定义的交易商，或者我没有在欧盟地区进行分发的计划”，并在销售范围排除欧盟。

![DSA compliance](assets/app-store-first-submit/41-dsa-compliance.png)

---

## 14. 中国大陆 ICP / App 备案

### 14.1 不要用普通网站备案号硬填 App 备案号

Apple 可能要求中国大陆 App Store 里的 App 提供 `ICP Filing Number`。普通网站备案号不一定够，App 备案号通常有 `A` 后缀。

备案没下来前，首发建议：

```text
App 销售范围排除中国大陆
IAP / 订阅销售范围排除中国大陆
```

备案完成后再打开中国大陆销售范围。

### 14.2 `dong4j.app` / `starcat.ink` / `dong4j.site`

当前结论：

- `dong4j.app` 部署在 Cloudflare，不适合作为国内备案入口。
- `dong4j.site` 已备案，但主体不是当前 Apple 开发者主体时，不建议混用。
- `starcat.ink` 如果域名实名主体已改为 `liwen gong`，可以用阿里云大陆资源尝试备案。

备案主体最好一致：

```text
Apple 开发者主体 = 域名实名主体 = App 备案主体 = 银行 / 税务主体
```

### 14.3 阿里云主体限制

阿里云账号通常只能有一个备案主体。如果现有阿里云服务器在另一个主体下，最干净的方案是：

```text
liwen gong 注册 / 实名阿里云账号
购买最低成本的大陆备案资源
使用 starcat.ink 提交新增网站备案或 App 备案
```

不要把已备案的个人主体、老婆的 Apple 主体、不同实名域名混在一起。

---

## 15. 加密合规

App 加密文稿一般不需要额外上传，除非使用了非标准加密或特殊加密用途。Starcat 使用的是常规 HTTPS / Keychain / 系统安全能力，通常按 Apple 出口合规问题如实回答即可。

![Encryption documentation](assets/app-store-first-submit/26-encryption-doc.png)

---

## 16. App-specific Shared Secret

App 专用共享密钥主要用于接收自动续期订阅收据数据的旧流程。当前 StoreKit 2 客户端购买和本地权益读取，不必现在生成。

如果未来后端做 App Store Server API / 通知校验，应优先使用现代 App Store Server API 的 Key 配置。

![App shared secret](assets/app-store-first-submit/14-app-shared-secret.png)

---

## 17. 小型企业计划

如果没有其他关联开发者账号，相关问题可以选“否”。这个用于申请 Apple Small Business Program，目标是符合条件时降低佣金比例。

![Small business program](assets/app-store-first-submit/25-small-business-program.png)

---

## 18. 提交审核前最终检查

提交 App Review 前检查：

- [ ] App 本体已设置 Free 定价。
- [ ] App 销售范围已排除中国大陆，除非 ICP 已通过。
- [ ] Monthly / Yearly / Lifetime 已挂到当前版本。
- [ ] Monthly / Yearly / Lifetime 状态至少为 `准备提交`。
- [ ] Paid Apps Agreement 已有效，或税务 / 银行流程已进入可提交状态。
- [ ] App Privacy 已按 Aptabase、GitHub、AI Provider 实际行为填写。
- [ ] Support / Marketing / Privacy URL 不包含 Direct 外部购买入口。
- [ ] App Store 包不包含 Creem / Waffo / Direct license / Sparkle 用户可见入口。
- [ ] TestFlight 内部测试已完成 GitHub 登录、订阅购买、恢复购买、Pro 门控验证。

---

## 19. 仍需单独跟进

- 中国大陆 ICP / App 备案：等 `starcat.ink` 主体和阿里云备案资源理顺后再处理。
- 欧盟 DSA：如果保留欧盟销售范围，补公开交易商信息。
- App Store 专用页面：继续完善 `dong4j.app/starcat/*`，确保无 Direct 支付入口。
- 订阅服务端校验：当前不是首发阻塞项，后续需要再接 App Store Server API。
