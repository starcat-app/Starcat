# StoreKit 订阅上架方案（已归并）

> 状态：已归并，不再作为支付体系单一信任源。

本文原 StoreKit 订阅策略、Pro 权益和 App Store 支付路径已归并到：

| 新文档 | 覆盖内容 |
|--------|----------|
| `docs/2-产品/需求讨论/支付对接.md` | App Store / Direct 支付需求入口 |
| `docs/2-产品/需求讨论/正式方案/支付对接正式方案.md` | StoreKit 与 Direct provider-neutral 支付正式方案 |
| `docs/3-设计/详细设计/40-支付对接详细设计.md` | StoreKit / Direct entitlement provider 详细设计 |
| `docs/4-工程进度/支付对接专项/checklist.md` | 支付对接实施 checklist |

StoreKit 2 的历史实施细节保留在：`docs/2-产品/需求讨论/正式方案/StoreKit订阅实施决策记录.md`。

App Store build 仍然只走 StoreKit / Apple IAP；Direct build 不显示 StoreKit 商品购买入口。
