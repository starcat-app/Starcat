# 支付对接专项 Checklist

> 创建：2026-07-04
> 状态：待实施
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

- [ ] `DistributionChannel` 注入支付路径
- [ ] `EntitlementProvider` 协议
- [ ] StoreKit 逻辑迁入 `StoreKitEntitlementProvider`
- [ ] `DirectEntitlementProvider`
- [ ] `DirectLicenseAPI`
- [ ] `DirectLicenseStore`
- [ ] License 设置页
- [ ] App Store build 隐藏 Direct license 入口
- [ ] Direct build 隐藏 StoreKit 商品购买入口

---

## 3. 后端

- [ ] Starcat License API skeleton
- [ ] `DirectPaymentProvider` 协议
- [ ] `DirectLicenseProvider` 协议
- [ ] Creem test mode adapter
- [ ] checkout endpoint
- [ ] activate / validate / deactivate endpoint
- [ ] customer portal endpoint
- [ ] webhook 验签与事件映射

---

## 4. 验证

- [ ] App Store build 无外部支付 URL / license 文案
- [ ] Direct build 无 StoreKit 商品入口
- [ ] Creem test mode 购买后 license 激活成功
- [ ] validate 后 Pro 状态刷新
- [ ] 退款 / 取消 / 过期后 Pro 状态取消
- [ ] 离线宽限期行为符合方案

