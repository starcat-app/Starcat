# Direct 分发与 Lemon Squeezy 授权方案（已归并）

> 状态：已归并，不再作为单一信任源。

本文原内容已拆分归并到：

| 新文档 | 覆盖内容 |
|--------|----------|
| `docs/2-产品/需求讨论/分发渠道.md` | App Store / Direct 分发渠道需求 |
| `docs/2-产品/需求讨论/支付对接.md` | Direct 支付、license 与授权需求 |
| `docs/2-产品/需求讨论/正式方案/分发渠道正式方案.md` | Direct 分发与 Sparkle 正式方案 |
| `docs/2-产品/需求讨论/正式方案/支付对接正式方案.md` | StoreKit / Direct provider-neutral 支付正式方案 |
| `docs/3-设计/详细设计/40-支付对接详细设计.md` | Direct license 与 provider adapter 详细设计 |
| `docs/3-设计/详细设计/41-分发渠道详细设计.md` | Direct target、Sparkle、打包脚本详细设计 |

后续不再以 Lemon Squeezy 作为唯一 Direct 支付方案。Creem 是 Direct 首期候选 provider，但 Starcat 必须通过 `DirectPaymentProvider` / `DirectLicenseProvider` 抽象保留多 provider 扩展能力。

