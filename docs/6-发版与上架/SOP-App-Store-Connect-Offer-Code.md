# App Store Connect — Offer Code 配置指南

> 创建：2026-06-19  
> 用途：在 App Store Connect 创建订阅优惠码，并在 Starcat 客户端兑换的完整 SOP  
> 关联代码：`OfferCodeRedemptionSupport.swift`、`SubscriptionManager.handleOfferCodeRedemptionResult`、`ProSettingsTab`、`ProPaywallSheet`  
> 前置阅读：`docs/2-产品/需求讨论/正式方案/StoreKit订阅上架方案.md`、`docs/2-产品/需求讨论/正式方案/Pro付费墙验证清单.md`

---

## 1. 机制说明（先读）

| 项 | 说明 |
|----|------|
| **谁发码** | 你在 **App Store Connect** 创建；Apple 生成/管理码 |
| **谁验码** | **Apple**（App Store / StoreKit）；Starcat **不**维护自建优惠券 API |
| **客户端入口** | SwiftUI `offerCodeRedemption` 系统兑换 sheet |
| **Pro 生效** | 兑换成功后 `Transaction.updates` + `handleOfferCodeRedemptionResult` 刷新权益 |
| **与 Promotional Offer 区别** | Offer Code = 发字符串码、App 外也可兑、**无需**服务器签名；见 `docs/2-产品/需求讨论/正式方案/StoreKit订阅上架方案.md` 讨论 |

Starcat 内入口：

1. **设置 → Pro** →「兑换优惠码」
2. **Pro 付费墙** →「兑换优惠码」

---

## 2. 前置条件

- [ ] App 已在 App Store Connect 创建，Bundle ID = `com.starcat.app`
- [ ] 自动续期订阅已创建且 **至少一个版本处于「准备提交」或已上架** 状态  
  （仅本地 `.storekit` 可跳过 Connect，但真机/TestFlight 必须 Connect 有商品）
- [ ] 订阅 Product ID 与代码一致：
  - `com.starcat.app.pro.yearly`
  - `com.starcat.app.pro.monthly`
- [ ] Xcode Scheme → Run → Options → **StoreKit Configuration**  
  - 开发：`Starcat/Resources/Products.storekit`  
  - TestFlight / 生产：选 **None**（走真实 App Store）

---

## 3. Connect 创建 Offer Code（逐步）

### 3.1 进入订阅定价页

1. 登录 [App Store Connect](https://appstoreconnect.apple.com)
2. **我的 App** → 选择 **Starcat**
3. 左侧 **订阅**（或 **App 内购买项目** → 订阅组 **Starcat Pro**）
4. 点目标订阅（建议先配 **年订** `Starcat Pro Yearly`）
5. 进入 **订阅价格**（Subscription Pricing）
6. 找到 **Offer Codes**（优惠码 / 订阅优惠码）→ **创建**（Create Offer Code）

### 3.2 选择优惠码类型

| 类型 | 适用场景 | 示例 |
|------|----------|------|
| **Custom Code（自定义码）** | 公开活动、固定口令 | `STARCATVIP`、`EARLYBIRD2026` |
| **One-time use codes（一次性码）** | 批量发给具体用户、KOL 名单 | 导出 CSV Thousands of unique codes |

**早鸟 / 博主推广** 通常用 **Custom Code**；**客服补偿 / 抽奖** 用 **One-time use**。

### 3.3 配置优惠方案

按 Connect 向导填写（字段名可能随 UI 迭代略有不同）：

1. **Reference Name（内部名）**  
   例：`Early Bird 2026 Yearly` — 仅后台可见

2. **Offer 类型 / 价格模式**（三选一）  
   - **Free（免费）**：优惠期内 $0  
   - **Pay up front（预付）**：例如首年 $19.99 一次性  
   - **Pay as you go（按期付）**：例如前 3 个月每月 $0.99  

3. **Duration（时长）**  
   例：1 个 **年** 订阅周期，或 3 个 **月** 周期（依模式而定）

4. **Customer Eligibility（用户资格）**  
   可多选：
   - 新订阅用户
   - 当前有效订阅用户
   - 已过期/已取消用户  

   **早鸟拉新**：至少勾选「新订阅用户」+「已过期用户」。

5. **与 Introductory Offer（试用）的关系**  
   Connect 会问：兑换码用户是否还能再用 Intro 试用？  
   - **Starcat v1 建议**：年订已配 14 天 Intro 时，Offer Code 选 **「否 — 先兑码价，不叠加 Intro」**，避免规则混乱。  
   - 具体以产品策略为准，创建后 **价格方案不可改**，只能新建 Offer。

6. **Custom Code 名称**（若选 Custom）  
   例：`STARCAT50` — 用户输入的字符串（大小写以 Connect 为准）

7. **兑换次数上限**  
   - Custom Code：可设总兑换上限（如 1000 次）  
   - 每 App 每季度最多约 **100 万次** 兑换（Apple 平台限额）

8. **生效日期**  
   设置开始 / 结束时间；过期后码失效。

9. **Review / 保存**  
   保存后 Connect 生成码或允许导出一次性码 CSV。

### 3.4 月订 vs 年订

- 每个 **订阅 SKU** 单独创建 Offer Code。  
- 早鸟年订 $19.99 → 在 **Yearly** 上建码；月订活动 → 在 **Monthly** 上另建。

---

## 4. 分发与兑换

### 4.1 用户如何兑换

| 渠道 | 操作 |
|------|------|
| **Starcat App 内（推荐）** | 设置 → Pro → **兑换优惠码**；或付费墙 → **兑换优惠码** |
| **App Store 账户** | 系统设置 → Apple 账户 → **兑换礼品卡或代码** |
| **Custom Code URL** | Connect 提供的 redemption URL（可放邮件 / 推文） |

### 4.2 兑换后 Starcat 行为

1. 系统 sheet 关闭  
2. `SubscriptionManager` 调用 `refreshEntitlements()`  
3. `isProUser == true` → 付费墙关闭、Pro 功能解锁  
4. 若未激活：用户可能取消了 sheet、码无效、或资格不符 — 检查 Connect 资格与 Sandbox 账号

**无需** Starcat 服务端验码。后续若接 App Store Server API，可在 transaction 的 `offerType == 3` 做分析，见 Apple 文档 [Supporting offer codes in your app](https://developer.apple.com/documentation/storekit/supporting-offer-codes-in-your-app)。

---

## 5. 本地开发测试（Xcode + `.storekit`）

### 5.1 配置文件

`Starcat/Resources/Products.storekit` 年订已含示例 Offer：

- **offerID**：`early_bird_yearly`  
- **referenceName**：`Early Bird Yearly`  
- **示例价**：$19.99 预付 1 年  

### 5.2 步骤

1. Xcode → Scheme **Starcat** → Edit Scheme → Run → **Options**  
2. **StoreKit Configuration** = `Products.storekit`  
3. 运行 App（`scripts/run-debug.sh` 或 Xcode Run）  
4. **Debug → StoreKit → Manage Transactions**  
5. 使用 StoreKit 测试工具创建 / 复制 **Offer Code** 测试码（Xcode 15+ 支持在 StoreKit 配置里管理）  
6. App 内 **设置 → Pro → 兑换优惠码**，输入测试码  
7. 确认 Pro 徽章出现、`EntitlementGate.isProUser == true`

### 5.3 Sandbox（Connect 已建码后）

1. App Store Connect → **用户和访问** → **Sandbox** → 创建测试员  
2. macOS **设置 → App Store → Sandbox 账户** 登录 Sandbox 账号  
3. Scheme 的 StoreKit Configuration 设为 **None**  
4. TestFlight 或 Development 签名包装机测试 Connect 里创建的 **Sandbox Offer Code**

---

## 6. 验收清单

| # | 检查项 | 通过 |
|---|--------|------|
| 1 | Connect 年订 Offer Code 已创建且处于有效期内 | [ ] |
| 2 | Custom Code / 一次性码 CSV 已导出并妥善保存 | [ ] |
| 3 | Starcat **设置 → Pro → 兑换优惠码** 能弹出系统 sheet | [ ] |
| 4 | 付费墙 **兑换优惠码** 同样可用 | [ ] |
| 5 | 有效码兑换后 Pro 立即生效（无需重启 App） | [ ] |
| 6 | 无效 / 过期码有 Apple 系统提示，App 不崩溃 | [ ] |
| 7 | 兑换后 **恢复购买** 仍正常 | [ ] |
| 8 | Sandbox 与 Production 各测至少 1 次 | [ ] |

完整 Pro 门控验收见 `docs/2-产品/需求讨论/正式方案/Pro付费墙验证清单.md`。

---

## 7. 常见问题

### Q1：点了「兑换优惠码」没反应？

- 确认 macOS **15+**（Starcat 最低版本）  
- 确认 Scheme 已选 StoreKit Configuration（本地）或 Sandbox 账号（真机）  
- 看设置页是否出现橙色错误提示

### Q2：兑了码但还不是 Pro？

- `Transaction.updates` 可能延迟 → 点 **恢复购买**  
- 检查码是否绑在 **正确 SKU**（年订码不能用于月订）  
- Sandbox 账号是否与兑换环境一致

### Q3：能用自建服务器发码吗？

**不能替代 Apple 订阅扣款。** 只能：

- 用 **Connect Offer Code**（本指南），或  
- App 外单独授权（Grandfather / 内测），不能与 App Store 订阅混为「官方优惠价」

### Q4：Offer Code 和 14 天免费试用叠加吗？

由 Connect 创建 Offer 时的选项决定；**创建后不可改 duration/type**，只能新建 Offer。

---

## 8. 关联文档

| 文档 | 关系 |
|------|------|
| `docs/2-产品/需求讨论/正式方案/StoreKit订阅上架方案.md` | v1 SKU、Intro 试用、门控总览 |
| `docs/2-产品/需求讨论/正式方案/Pro付费墙验证清单.md` | Pro 功能人工验收 |
| `docs/2-产品/需求讨论/正式方案/StoreKit订阅实施决策记录.md` | 为何 v1 不做 Server API 验签 |
| [Apple — Set up subscription offer codes](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-subscription-offer-codes/) | Connect 官方帮助 |
| [Apple — Supporting offer codes in your app](https://developer.apple.com/documentation/storekit/supporting-offer-codes-in-your-app) | StoreKit 客户端说明 |

---

## 9. 变更日志

| 日期 | 变更 |
|------|------|
| 2026-06-19 | 初版：客户端接入 Offer Code 兑换 + Connect 配置 SOP |
