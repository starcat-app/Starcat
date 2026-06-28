# Pro 付费墙验证清单

> 创建：2026-06-18
> 用途：StoreKit 订阅门控上线后，人工逐项验收「免费用户触发 Pro 能力 → 弹出 `ProPaywallSheet`」的单一走查清单
> 前置阅读：`docs/2-产品/需求讨论/正式方案/StoreKit订阅上架方案.md` §5.1、`docs/2-产品/需求讨论/正式方案/PRO 订阅功能划分.md`
> 维护：修复门控 / 新增 Pro 能力后同步更新本清单；每项验收通过打勾 `[x]`

---

## 0. 验收总则

### 0.1 通过标准（每条都要满足）

- [ ] 弹出 **`ProPaywallSheet`**（统一订阅页），**不是**普通 `alert`「失败 + 重试」
- [ ] 说明文案与功能匹配（如「AI 摘要」「CodeFlow 代码图谱」）
- [ ] 可正常关闭付费墙，原界面状态不被破坏
- [ ] **Pro 订阅后**（StoreKit 沙盒 / `.storekit` 本地配置）同一操作**不再**弹墙

### 0.2 测试前准备

| 项 | 说明 |
|----|------|
| 账号状态 | `设置 → Pro` 显示**未订阅** |
| StoreKit | 开发期用 Xcode `.storekit` 配置；TestFlight 用 Sandbox Tester |
| AI 策略 | 免费版零 AI；BYOK 配置与 AI 工作流均为 Pro-only |
| 数量上限 | 标签 **≤20**；Release 订阅 **≤5**（已订阅的不占新增名额） |

### 0.3 推荐验收顺序

```
AI 设置页锁定态 → 分享 → AI 生成摘要 → AI 发消息 → CodeFlow → ⌘K Web → 第 21 标签 → 第 6 Release 订阅
→ README 翻译 → Untagged 批量整理 → 语义搜索 / 自动整理（对照已知缺口）
```

---

## 1. 免费用户触发 AI → 付费墙（无 App 内次数试用）

门控：`EntitlementGate.requirePro(.aiSummary | .aiTags | .aiChat | ...)`  
错误类型：`EntitlementGateError.requiresPro`

### 1.0 AI 设置页 `BYOK`

| # | 操作路径 | 触发条件 | 通过 |
|---|----------|----------|------|
| A0 | 设置 → **AI 服务** | 未订阅 Pro | 仅显示 Pro 锁定态与升级入口，不显示 Provider / API Key 表单 [ ] |

### 1.1 AI 摘要 `aiSummary`

| # | 操作路径 | 触发条件 | 通过 |
|---|----------|----------|------|
| A1 | 仓库详情 → **AI** → 摘要 Tab → **生成摘要** | 免费用户首次生成（无缓存） | [ ] |
| A2 | 同上 → 空态 **「开始分析」** | 同上 | [ ] |
| A3 | 已有摘要 → **设置已变更，重新生成** banner | 同上 | [ ] |
| A4 | 仓库详情 → **分享** | 无缓存时需先生成摘要；免费用户应弹付费墙（非「分享失败 + 重试」） | [ ] |

**代码入口**：`RepoAIInsightService.enforceGenerationEntitlement` → `RepoAIInsightViewModel` / `RepoShareButton`  
**付费墙承载**：AI 窗口 `RepoAIWindowContentView`；分享 `RepoShareButton` 本地 sheet

### 1.2 AI 标签推荐 `aiTags`

| # | 操作路径 | 触发条件 | 通过 |
|---|----------|----------|------|
| A5 | AI 窗口 → 生成摘要（已 star 仓库，`includeTags=true`） | 标签试用第 4 次（与摘要试用**独立计数**） | [ ] |
| A6 | AI 窗口 → **应用标签** / **全部应用** | 若同时触发新建标签且已有 20 个 → 见 §2.1 | [ ] |

---

## 2. 数量上限 → 付费墙

### 2.1 标签创建 `tagCreation`（免费 ≤20）

| # | 操作路径 | 触发条件 | 通过 |
|---|----------|----------|------|
| B1 | Sidebar Tags → **管理**（或 `Cmd+,` 相关入口）→ **新建标签** | 已有 **20** 个标签时再建第 21 个 | [ ] |
| B2 | AI 窗口 → 应用 AI 推荐的新标签名 | 同上（`GatedTagRepository.create`） | [ ] |

**代码入口**：`EntitlementGate.validateTagCreation` → `GatedTagRepository`  
**付费墙承载**：`TagManagementView` + `TagManagementViewModel.paywallContext`

### 2.2 Release 订阅 `releaseSubscription`（免费 ≤5）

| # | 操作路径 | 触发条件 | 通过 |
|---|----------|----------|------|
| B3 | 仓库详情 hero → **Releases** stat（🔔 订阅） | 已订阅 **5** 个不同仓库后再订阅第 6 个 | [ ] |

**代码入口**：`GatedReleaseSubscriptionRepository.subscribe`  
**付费墙承载**：`RepoReleaseStatItem` → `RepoReleaseSectionViewModel.paywallContext`

**注意**：未登录点击会先走 OAuth 设备流，**不是**付费墙。

---

## 3. Pro-only → 付费墙（无试用）

门控：`EntitlementGate.requirePro(_:)`

### 3.1 AI 对话 `aiChat`

| # | 操作路径 | 通过 |
|---|----------|------|
| C1 | 仓库详情 → **AI** → 对话 Tab → 输入消息 → **发送 / Enter** | [ ] |

**说明**：打开 AI 窗口本身免费；**发消息时**才门控。  
**代码入口**：`RepoAIInsightService.chatStream`  
**付费墙承载**：`RepoAIWindowContentView`

### 3.2 README 翻译 `readmeTranslation`

| # | 操作路径 | 通过 |
|---|----------|------|
| C2 | Manage / Trending / Activity / Weekly 详情 → README → **翻译** | [ ] |
| C3 | 翻译 stale 提示 → **重新生成** | [ ] |

**代码入口**：`ReadmeTranslationService.translate`  
**付费墙承载**：`HomeView` 统一 sheet（`ReadmeTranslationViewModel.paywallContext`）

### 3.3 批量 AI 整理 `batchAI`

| # | 操作路径 | 通过 |
|---|----------|------|
| C4 | Sidebar → **Untagged** → banner **开始整理** → 选项 sheet → 确认启动 | [ ] |

**说明**：在队列启动**之前**门控，不应进入进度面板后才报错。  
**代码入口**：`HomeView.startBatchAIIntegration` + `BatchAIQueueService.start`  
**付费墙承载**：`HomeView.paywallContext`

### 3.4 AnySearch Web `anySearchWeb`

| # | 操作路径 | 预期 | 通过 |
|---|----------|------|------|
| C5 | `⌘K` → scope **Web** → 输入关键词 → **回车** | 付费墙 | [ ] |
| C6 | `⌘K` → scope 切到 **Web**（即使尚未搜索） | 付费墙（`changeScope` 时检查） | [ ] |
| C7 | 设置 → 集成 → 开 AnySearch + **All 含 Web** → `⌘K` → scope **All** → 搜索 | ⚠️ 见 §5.1 | [ ] |

**代码入口**：`SearchCenterViewModel.canRunExplicitWebSearch` / `AnySearchWebProvider.search`  
**付费墙承载**：`SearchCenterView`（`SearchCenterViewModel.paywallContext`）

### 3.5 语义搜索 `semanticSearch`

| # | 操作路径 | 预期 | 通过 |
|---|----------|------|------|
| C8 | Manage 列表 toolbar 搜索框 → 模式 **语义搜索** → 输入 query | ⚠️ 见 §5.2 | [ ] |
| C9 | 同上 → 菜单 **刷新语义索引** | ⚠️ 见 §5.2 | [ ] |

**代码入口**：`SemanticSearchService.search` / `refreshIndex`  
**当前 UI**：`HomeViewModel.loadError` 文案，**不弹付费墙**

### 3.6 CodeFlow `codeFlow`

| # | 操作路径 | 通过 |
|---|----------|------|
| C10 | Manage 详情 toolbar → 外链菜单 **CodeFlow** 渐变卡 | [ ] |
| C11 | Trending / Weekly / Activity 选中公开仓库 → toolbar 同上 | [ ] |
| C12 | `⌘K` → GitHub 结果详情 → **···** → CodeFlow 卡 | [ ] |
| C13 | 已打开 CodeFlow 面板 → **生成 / 打开 / 重新生成**（二次校验） | [ ] |

**代码入口**：`RepoListView.openCodeFlow` / `SearchRemoteRepoDetailView` / `CodeFlowPanel.requireCodeFlowAccess`  
**付费墙承载**：各入口本地 `paywallContext` sheet

### 3.7 自动整理 `autoOrganize`

| # | 操作路径 | 预期 | 通过 |
|---|----------|------|------|
| C14 | `Cmd+,` → AI 设置 → 自动整理 → **立即运行** | ⚠️ 见 §5.3 | [ ] |
| C15 | 开启同步后 / 启动延迟 / 24h 定时触发（后台） | ⚠️ 见 §5.3 | [ ] |

**代码入口**：`AutoTidyScheduler.runOnce`  
**当前行为**：门控失败**静默跳过**（仅日志），不弹付费墙

---

## 4. 不应弹付费墙（回归对照）

验收 Pro 门控时，顺带确认以下路径**保持免费**：

| # | 操作 | 预期 | 通过 |
|---|------|------|------|
| D1 | `⌘K` → scope **Local** / **GitHub** 搜索 | 正常出结果 | [ ] |
| D2 | Manage 列表 **关键词** FTS 搜索 | 正常出结果 | [ ] |
| D3 | 打开 AI 窗口 → 查看**已有缓存**摘要（不点生成） | 不弹墙 | [ ] |
| D4 | Stars 同步、标签浏览、README 阅读、笔记编辑 | 不弹墙 | [ ] |
| D5 | 设置 → 集成 → CodeFlow **输出目录 / 用量统计**（仅配置） | 不弹墙 | [ ] |

---

## 5. 已知缺口（验收时单独记录）

以下路径**已有门控逻辑**，但 UI **尚未**统一弹 `ProPaywallSheet`，后续应补齐：

| ID | 场景 | 当前表现 | 关联代码 |
|----|------|----------|----------|
| G1 | `⌘K` scope **All** + 设置开启「All 含 Web」 | Web 源搜索失败，可能只显示来源 error | `SearchCenterViewModel.canRunExplicitWebSearch` 仅检查 `.web` |
| G2 | Manage **语义搜索** / **刷新语义索引** | 列表 `loadError` 文案 | `HomeViewModel.reloadItems` / `refreshSemanticIndex` |
| G3 | **自动整理**手动 / 后台触发 | 静默跳过，无用户可见反馈 | `AutoTidyScheduler.runOnce` |

---

## 6. 尚未门控（暂无可测付费墙）

| ProFeature | 状态 | 说明 |
|------------|------|------|
| `.repoContext` | 枚举已定义，**未接 `requirePro`** | AI 设置里 RepoContext 开关仍可用 |
| `.cloudSync` | 预埋 | CloudKit v1 不做，上线后再门控 |

---

## 7. ProFeature ↔ 代码索引

| ProFeature | 门控方式 | 主要 UI 入口 |
|------------|----------|--------------|
| `.aiSummary` | Pro only | AI 摘要生成、分享 |
| `.aiTags` | Pro only | AI 摘要（含标签）、应用标签 |
| `.aiChat` | Pro only | AI 对话发送 |
| `.batchAI` | Pro only | Untagged 批量整理 |
| `.autoOrganize` | Pro only | 自动整理调度（⚠️ 无付费墙 UI） |
| `.readmeTranslation` | Pro only | README 翻译 |
| `.semanticSearch` | Pro only | 语义搜索（⚠️ 无付费墙 UI） |
| `.anySearchWeb` | Pro only | ⌘K Web scope |
| `.repoContext` | 未接门控 | — |
| `.releaseSubscription` | 免费 ≤5 | Releases 订阅 stat |
| `.tagCreation` | 免费 ≤20 | 标签管理 / AI 应用新标签 |
| `.codeFlow` | Pro only | 详情 toolbar / 搜索详情 |
| `.cloudSync` | 未上线 | — |

**单一信任源（门控实现）**：`Starcat/Core/Subscription/EntitlementGate.swift`  
**付费墙 UI**：`Starcat/Core/Subscription/ProPaywallSheet.swift`（统一 `ProPaywallSheet.hosted`）

---

## 8. 变更日志

| 日期 | 变更 |
|------|------|
| 2026-06-18 | 初版：覆盖 v1 StoreKit 分支全部已接门控入口 + 已知缺口 G1–G3 |
