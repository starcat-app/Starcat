# StoreKit 订阅实施决策记录

> 创建：2026-06-18
> 用途：记录本轮 Apple Store 订阅服务实施中由 AI 先行采用的工程决策，供 dong4j 后续复核。
> 适用范围：`codex/storekit-subscriptions` 分支。

---

## 1. 本轮目标

本轮一次性完成 App Store 上架前必须具备的订阅闭环：

1. StoreKit 2 订阅底座：商品加载、购买、恢复、权益刷新、交易更新监听。
2. Pro 设置页：展示真实商品、购买、恢复、管理订阅、当前权益状态。
3. 统一付费墙：所有 Pro-only 或 quota 超限入口给一致反馈。
4. 最小真实门控：AI、Release 订阅、标签数量这些会影响成本或商业边界的入口必须落地。
5. 本地 `.storekit` 测试配置、i18n、单测与工程进度文档同步。

## 2. 默认决策

### D-StoreKit-1：首版只实现月订 + 年订

采用：

- `com.starcat.app.pro.monthly`
- `com.starcat.app.pro.yearly`

不在本轮实现 lifetime 买断。原因：买断是非消耗型商品，与自动续期订阅在权益、文案、退款和价格策略上需要额外设计；上架前先把订阅闭环做稳。

### D-StoreKit-2：客户端 StoreKit 权益作为 v1 单一真相源

本轮不接 App Store Server API，不做服务端票据校验。原因：

- Starcat 当前是 macOS 本地优先应用，付费权益主要控制客户端功能入口。
- v1 目标是可提审、可购买、可恢复、可响应订阅过期。
- 服务端票据校验更适合后续自建 AI 代理按订阅状态放行时接入。

### D-StoreKit-3：`AppSettings.isProUser` 保留为 UI 镜像

`AppSettings.isProUser` 不再由设置页直接写入，只由订阅权益刷新链路更新。原因：

- 现有头像 PRO 标识、分享卡等 UI 已消费这个字段。
- 直接删除会扩大改动面。
- 作为只读镜像能兼容现有 UI，同时避免本地模拟状态污染真实订阅逻辑。

### D-StoreKit-4：试用配额先按 GitHub User ID + 本机持久化记录

免费 AI 试用次数按当前 GitHub User ID 计数；未登录时使用 `_anonymous` 命名空间。原因：

- 现有应用主工作流依赖 GitHub 登录，GitHub User ID 是最稳定的本地用户标识。
- v1 不引入服务端账号系统，不做跨设备防重装绕过。
- 后续如果接服务器，可把同一抽象替换为远端 quota。

### D-StoreKit-5：已生成/已缓存数据继续可读，只拦截新增高成本动作

免费用户仍可查看已有 AI 摘要、已有 README 翻译、已有向量索引产生的普通列表数据；但重新生成、搜索时创建 embedding、AI Chat、批量整理等新动作需要 Pro 或试用配额。原因：

- 避免早期开发期用户已有数据突然不可见。
- 付费边界应拦在成本动作，而不是拦历史内容读取。

### D-StoreKit-6：本轮不做早鸟永久 Pro

暂不实现 grandfather / legacy grant。原因：

- 当前产品尚未正式上线，没有需要迁移的线上付费用户。
- 永久授权一旦写入，后续撤回成本高。
- 如 dong4j 后续需要早鸟权益，可基于 `EntitlementGate` 增加本地 grant 或服务端 grant。

### D-StoreKit-7：管理订阅入口使用 Apple 账户订阅管理 URL

实施时用 `https://apps.apple.com/account/subscriptions` 打开 Apple 账户订阅管理页，暂不调用 `AppStore.showManageSubscriptions`。原因：

- 当前本机 macOS SDK 对 `AppStore.showManageSubscriptions` 做 `swiftc -typecheck` 校验时不可用；
- v1 提审要求是用户能找到管理 / 取消订阅入口，官方账户订阅管理 URL 可以满足；
- 后续 SDK 提供 macOS 原生管理面板后，只需替换 `SubscriptionExternalLinks.manageSubscriptions`。

## 3. 本轮门控边界

### Pro 或试用

- 单仓 AI 摘要
- 单仓 AI 标签推荐

### Pro only

- AI Chat
- 批量 AI 整理
- 自动后台 AI 整理
- README 重新翻译
- 语义搜索 / embedding
- AnySearch Web 搜索

### 免费限额

- 标签创建：最多 20 个
- Release 订阅：最多 5 个

## 4. 暂不实施项

- CloudKit / iCloud entitlement
- lifetime 买断 SKU
- App Store Server API
- 月度 AI 总次数池
- 菜单栏、Spotlight、Widget 等未实现功能的门控

---

后续如果实施过程中出现需要 dong4j 决策的问题，AI 会先按最小可上架、最少架构债的方案实现，并把决策追加到本文。
