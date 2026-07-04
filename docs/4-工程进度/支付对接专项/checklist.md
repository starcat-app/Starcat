# 支付对接专项 Checklist

> 创建：2026-07-04
> 状态：已完成首期实现
> 需求入口：`docs/2-产品/需求讨论/支付对接.md`
> 正式方案：`docs/2-产品/需求讨论/正式方案/支付对接正式方案.md`
> 详细设计：`docs/3-设计/详细设计/40-支付对接详细设计.md`

---

## 1. 文档与决策

- [x] 支付对接需求讨论入口落档 — `docs/2-产品/需求讨论/支付对接.md` — 2026-07-04
  > 实现：将 StoreKit、Direct license、Creem 候选和多 provider 抽象收敛到支付对接主线。
- [x] 支付对接正式方案落档 — `docs/2-产品/需求讨论/正式方案/支付对接正式方案.md` — 2026-07-04
  > 实现：明确 App Store 走 StoreKit、Direct 走 provider-neutral License API，Creem 只作为首期候选。
- [x] 支付对接详细设计落档 — `docs/3-设计/详细设计/40-支付对接详细设计.md` — 2026-07-04
  > 实现：定义 EntitlementProvider、DirectLicenseAPI、License Store、后端接口和 provider adapter 边界。

---

## 2. 客户端

- [x] `DistributionChannel` 注入支付路径 — `Starcat/Features/Settings/ProSettingsView.swift` — 2026-07-04
  > 实现：Pro 设置页按渠道切换 StoreKit 商品区与 Direct License 授权区。
- [x] `EntitlementProvider` 协议 — `Starcat/Core/Subscription/ProEntitlement.swift` — 2026-07-04
  > 实现：复用并扩展现有 `ProEntitlementProviding`，新增 `directLicense` 来源。
- [x] StoreKit provider 接入聚合权益 — `Starcat/Core/Subscription/CompositeProEntitlementProvider.swift` — 2026-07-04
  > 实现：保留 `SubscriptionManager` 作为 StoreKit provider，并由聚合 provider 统一暴露给门控。
- [x] `DirectEntitlementProvider` — `Starcat/Core/Subscription/DirectLicenseManager.swift` — 2026-07-04
  > 实现：Direct License 管理器实现 `ProEntitlementProviding`，激活/校验后刷新 Pro 权益。
- [x] `DirectLicenseAPI` — `Starcat/Core/Subscription/DirectLicenseAPI.swift` — 2026-07-04
  > 实现：客户端只调用 Starcat License API，不直接接触 Creem。
- [x] `DirectLicenseStore` — `Starcat/Core/Subscription/DirectLicenseStore.swift` — 2026-07-04
  > 实现：授权码与 instance id 复用本地加密凭据文件存储。
- [x] License 设置页 — `Starcat/Features/Settings/ProSettingsView.swift` — 2026-07-04
  > 实现：Direct 版提供授权码激活、校验和解绑入口。
- [x] App Store build 隐藏 Direct license 入口 — `Starcat/Features/Settings/ProSettingsView.swift` — 2026-07-04
  > 实现：App Store 渠道只展示 StoreKit 商品和 Apple 账户操作。
- [x] Direct build 隐藏 StoreKit 商品购买入口 — `Starcat/Features/Settings/ProSettingsView.swift` — 2026-07-04
  > 实现：Direct 渠道不展示 StoreKit 商品、恢复购买和 Offer Code。

---

## 3. 后端

- [x] Starcat License API skeleton — `supports/starcat-license-api` — 2026-07-04
  > 实现：新增独立 Go 服务，提供 healthz、Direct license、checkout、customer portal 和 webhook 端点。
- [x] `DirectPaymentProvider` 协议 — `supports/starcat-license-api/internal/provider/payment.go` — 2026-07-04
  > 实现：新增 `PaymentProvider` / `StaticPaymentProvider`，handler 只依赖 provider-neutral 接口，Creem URL 由环境变量配置。
- [x] `DirectLicenseProvider` 协议 — `supports/starcat-license-api/internal/provider/provider.go` — 2026-07-04
  > 实现：定义 activate/validate/deactivate provider 接口。
- [x] Creem test mode adapter — `supports/starcat-license-api/internal/provider/creem.go` — 2026-07-04
  > 实现：支持 Creem test API base、API key、license activate/validate/deactivate 和状态归一化。
- [x] checkout endpoint — `supports/starcat-license-api/internal/handler/payment.go` — 2026-07-04
  > 实现：`POST /v1/direct/checkout` 返回配置的 Creem checkout URL。
- [x] activate / validate / deactivate endpoint — `supports/starcat-license-api/internal/handler/license.go` — 2026-07-04
  > 实现：三类 License 端点统一校验请求并转发 provider。
- [x] customer portal endpoint — `supports/starcat-license-api/internal/handler/payment.go` — 2026-07-04
  > 实现：`POST /v1/direct/customer-portal` 返回配置的 Creem customer portal URL。
- [x] webhook 验签与事件映射 — `supports/starcat-license-api/internal/handler/webhook.go` — 2026-07-04
  > 实现：校验 `creem-signature` HMAC-SHA256 并返回事件 id/type。

---

## 4. 验证

- [x] App Store build 无外部支付 URL / license 文案 — `Starcat/Features/Settings/ProSettingsView.swift` — 2026-07-04
  > 实现：App Store 渠道不渲染 Direct License section；后续审查继续做产物字符串抽检。
- [x] Direct build 无 StoreKit 商品入口 — `Starcat/Features/Settings/ProSettingsView.swift` — 2026-07-04
  > 实现：Direct 渠道不加载 StoreKit products，也不展示恢复购买 / Offer Code / Apple 管理入口。
- [x] Creem test mode license adapter 单测 — `supports/starcat-license-api/internal/provider/creem_test.go` — 2026-07-04
  > 实现：用 httptest 覆盖 Creem activate 请求头、路径、状态和 instance id 归一化。
- [x] validate 后 Pro 状态刷新 — `Starcat/Core/Subscription/DirectLicenseManager.swift` — 2026-07-04
  > 实现：`validateStoredLicense()` 成功后通过 Direct snapshot 刷新聚合 Pro 权益。
- [x] 退款 / 取消 / 过期后 Pro 状态取消 — `Starcat/Core/Subscription/DirectLicenseModels.swift` — 2026-07-04
  > 实现：`expired` / `revoked` snapshot 映射为 inactive，聚合权益不再放行。
- [x] 离线宽限期行为符合方案 — `Starcat/Core/Subscription/DirectLicenseStore.swift` — 2026-07-04
  > 实现：首期不做离线宽限放行；本地仅保存 credential，Pro 激活以最近一次服务端校验结果为准。
