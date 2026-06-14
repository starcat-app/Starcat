# Starcat Companion Chrome 插件 — 方案问题记录

> **状态**：评审中（2026-06-14 由 studio.cursor 整理）
> **关联**：
> - 评审对象：[`chrome插件-最终方案.md`](./chrome插件-最终方案.md) v1.1（2026-06-13 dong4j 拍板 Q1/Q3/Q5/Q8 之后版本）
> - 详细设计：[`../详细设计/23-Chrome-插件方案.md`](../详细设计/23-Chrome-插件方案.md) v1.0（同源问题在此文档同样存在）
> - 初稿（已弃用）：[`chrome插件-需求初稿.md`](./chrome插件-需求初稿.md)
> - 触发 issue：[HOM-197](mention://issue/c8e10c21-5e72-4e51-b95a-966b1f3eea6f)
>
> **本文档目的**：把 `chrome插件-最终方案.md` 与客户端代码现状之间的偏差、文档未覆盖的技术风险、施工路径里的隐性返工点集中记录，作为开工前修订方案与排前置任务的依据。

---

## 0. 一句话评审结论

> **战略对，战术撞墙**。三闭环定位（正向采集 / 反向投射 / 触发 AI 摘要）+ App 端做重活 + 严守隐私边界，方向完全正确；但方案文档把 3 处「客户端还没有的能力」当成「现状已有」在用，按它写的施工路径，M1 / M2 里程碑直接撞墙。同时 4 条关键技术风险（PNA / Sandbox / 多账号 / 隐式 capture race）文档没覆盖。

---

## 1. 评审范围与方法

### 1.1 评审范围

| 维度 | 是否纳入 |
|---|---|
| 方案与客户端代码现状的一致性 | ✅ |
| 方案与已落地数据库 schema（v1-initial）的一致性 | ✅ |
| Chrome MV3 / macOS Sandbox / 浏览器侧落地可行性 | ✅ |
| 隐私边界与降级策略是否完备 | ✅ |
| 工期是否覆盖隐藏子任务 | ✅ |
| UI mock / 视觉细节 | ❌（方案明确不涉及，留施工阶段） |
| 后端 4 服务改造 | ❌（方案明确不动后端） |

### 1.2 评审方法

- 全文阅读 `chrome插件-最终方案.md` + `23-Chrome-插件方案.md`
- 对照客户端代码核对方案反复引用的「现状前提」：
  - `Starcat/Core/Database/Migrations/DatabaseMigrationsV1.swift`（schema 现状）
  - `Starcat/Features/Activity/ActivityModels.swift`（Activity 分类现状）
  - `Starcat/Core/Network/WeeklyModels.swift`（`source_types` / `WeeklySource` 现状）
  - `Starcat/Core/Keychain/KeychainManager.swift`（凭证存储现状）
  - `Starcat/Shared/Utilities/Constants.swift` + `Generated/Info.generated.plist`（URL Scheme 现状）
  - `Starcat/Features/Auth/GithubDeviceFlowService.swift`（OAuth 回调链路现状）
- 全工程 grep 验证关键 API 是否存在：`onOpenURL` / `kAEInternetEventClass` / `NSAppleEventManager` / `companion.token` / `last_seen_at` / `source_types`

---

## 2. 问题清单（按严重度分三档）

### 🟥 红线问题（开工前必须先解决，否则方案无法施工）

#### P0-1：R-04 「`github_repos` 主表」客户端根本不存在

**方案出处**：§2「现状摘要」表格、§3.1 闭环 A、§4.3 F2、§8 对接清单、§14.1 文档同步清单 —— 全文 8+ 处把它当作客户端现成的表在用。

**实际现状**：

| 客户端真实存在的表 | 用途 | 是否含 `source_types` |
|---|---|---|
| `repos`（28 列） | 已 star / 曾 star 的 repo 镜像（`is_starred` 标记软删除） | ❌ |
| `trending_repos` | trending 缓存 | ❌ |
| `repo_embeddings` | 向量化索引 | ❌ |
| `ai_summaries` | AI 摘要缓存 | ❌ |
| `release_subscriptions` / `releases` / `readme_translations` / `repo_notes` / `tags` / `repo_tags` / `readmes` / `repos_fts` / 等 | 附表 | ❌ |

`source_types: [WeeklySource]` 字段**只存在于** `WeeklyModels.swift::WeeklyFeedRepoDTO` —— 它是 `starcat-weekly-api` 后端聚合接口返回的 **网络 DTO**，从未落到客户端任何 SQLite 表里。

也就是说"R-04 主表"目前完全是**后端概念**，客户端从未复刻。

**按方案 F2 「入主表 `github_repos`，`source_types += {clip}`」要怎么落？两条路：**

| 选项 | 改动 | 工期 |
|---|---|---|
| (a) 扩 `repos` 表 | 加 `source_types`（TEXT，JSON 数组） / `last_seen_at`（TEXT ISO8601） / 必要的索引；F2 写入路径走 `RepoRepository.upsertFromClip(...)` | ≥ 5 天（含数据迁移决策、`is_starred` 与 `source_types` 语义协调、所有 SELECT 查询梳理） |
| (b) 新建 `clipped_repos` 表 | FK 到 `repos.id`，Activity Inbox 从这张表读；优点：不动 v1-initial 主表；缺点：Inbox 与已 star repo 的关联查询要 JOIN | ≥ 3 天 |

**无论选哪条，都不是方案宣称的"零新表 / 零新 schema 改动"，也不是 §11 M2「2~3 天」能搞定的。**

**建议**：开工前先开一个「R-04 客户端化设计稿」小 issue 决定走 (a) 还是 (b)，再修订方案 §4.3 / §8 / §11。

---

#### P0-2：客户端**没有任何 Deep Link 路由器**，5 个 action 是从 0 搭

**方案出处**：§2「现状摘要」最后一行 "Deep Link 已规划但未全量实现，路由器待施工时统一扩展"、§8「Deep Link Router 加 5 个 action 路由」、§11 M2「2~3 天扩展 deep link 路由」、`23-Chrome-插件方案.md` §9.1 数据流图「Deep Link Router（已有，扩展 5 个 action）」。

**实际现状**：

- `Info.generated.plist` 注册了 `CFBundleURLSchemes = ["starcat"]`
- `Constants.swift` 定义了 `oauthCallbackURL = "starcat://callback"`（**为 OAuth 留的占位**）
- 但 GitHub OAuth 实际走的是 **Device Flow**（`GithubDeviceFlowService.swift`，用户在浏览器输入 `verification_uri` + user_code，**不走 URL callback**）
- 全工程 grep：
  - `onOpenURL` → 0 命中（应用层）
  - `kAEInternetEventClass` → 0 命中
  - `NSAppleEventManager` → 0 命中
  - `handleOpenURL` → 0 命中

**结论**：URL scheme 名义上注册了，但 App 内**完全没有 handler**。`starcat://callback` 是历史规划的占位 URL，实际链路没接通。

**真实工作量**：

1. 在 `Starcat/App` 注册 `.onOpenURL { handleStarcatURL($0) }` 或 `.handlesExternalEvents`
2. 建立 `URLRouter` actor / `StarcatURL` enum，5 个 action 类型安全解析
3. 参数校验、URL 解码、容错（非法 fullname / 缺参数 / 未知 action）
4. 失败 toast / 错误日志
5. 跨详情页跳转（与 `RepoResolverChain` 对接）
6. 单元测试

**最少 2~3 天**，方案 §11 M2「2~3 天」要把这事 + Activity Inbox 分类 + R-04 写入路径全做完，**完全不够**。

**建议**：先做一个 0.5 天的 PoC（注册 `.onOpenURL` + 1 个空 action，在终端 `open "starcat://test"` 能在 App 端打印日志），验证 macOS URL Scheme 唤起链路在当前 entitlement 下没卡点，再投全量。

---

#### P0-3：Activity 现状是 **7 个分类**，不是文档反复说的 8 个含 `discovery`

**方案出处**：§2「Activity 聚合页 已上线 8 个具体分类（`announcement / release / star / repository / following / suggestion / weekly` + 规划中的 `discovery`）」、§3.1「Activity 第 9 个子分类」、§4.3「Sidebar 列表 Activity root 下追加一行（与 weekly / discovery 同级）」。

**实际现状**（`Starcat/Features/Activity/ActivityModels.swift`）：

```swift
enum ActivityCategory: String, CaseIterable, Identifiable, Sendable {
    case all              // ← 全部聚合视图
    case announcement
    case release
    case star
    case repository
    case following
    case suggestion
    case weekly
    // ← 没有 discovery
}
```

**`WeeklySource.discovery` ≠ `ActivityCategory.discovery`**：

- `WeeklySource.discovery` 是 `starcat-weekly-api` 后端给 weekly 接口返回的源标签之一（对应 Hacker News），用于在 weekly feed 卡片上显示来源徽章
- 方案把它误读成了 Activity sidebar 上的独立分类

**影响**：

- Inbox 是 Activity 的**第 8 个**分类（不是方案说的"第 9 个"）
- §4.3 改造清单里"Sidebar Activity root 下追加一行 与 weekly / discovery 同级" —— **sidebar 上压根没有 discovery 行**
- §15 验收标准描述（"sidebar 可见，能列出 source_types ⊇ {clip}"）需要相应订正

**建议**：方案 §2 / §3.1 / §4.3 / §15 全部把"8 个分类含 discovery"改成"7 个分类"，"第 9 个子分类"改成"第 8 个子分类"。

---

#### P0-4：Chrome MV3 + 本地 HTTP 的两条关键技术风险方案没覆盖

**方案出处**：§9.2 Manifest 最小权限、§13 R2「Chrome 插件 fetch 127.0.0.1 受 CORS / mixed content 限制」、§5.2 反向链路。

**方案覆盖到的**：`Access-Control-Allow-Origin: chrome-extension://<id>`。

**方案漏掉的两条会让胶囊 fetch 直接失败的点**：

| 风险 | 详情 | 严重度 |
|---|---|---|
| **Private Network Access (PNA)** | Chrome 130+ 对 public web context（含 `github.com`）跨网段访问 `127.0.0.1` 强制走 preflight，要求响应头 **`Access-Control-Allow-Private-Network: true`**，否则浏览器直接 block。这是 MV3 反向链路最大的坑，**不是 CORS**。 | 🔴 致命：F1/F4 全部失效 |
| **MV3 Service Worker 30s idle 销毁** | `chrome.tabs.onActivated` 监听 / 插件 60s 缓存 / 角标更新 全部要在 worker 重启后重建。首次切 tab 会有冷启动延迟（~100~300ms），影响 F4 角标体验。 | 🟡 体验：角标偶尔延迟出现 |

**建议**：

1. 方案 §13 R2 改写：「Chrome MV3 fetch `http://127.0.0.1` 受 **Private Network Access** 限制」（不是 CORS），App 端 HTTP 响应必须返回 `Access-Control-Allow-Private-Network: true` + `Access-Control-Allow-Origin: chrome-extension://<id>` + `Access-Control-Allow-Headers: Authorization` 三件套
2. 方案 §4.5 / §9.1 数据通路补一句「service worker 唤起延迟」对角标首屏的影响 + 缓解（启动时立即给当前活跃 tab 主动 fetch 一次）
3. **开工前做一个 50 行最小 PoC**（SwiftNIO 在 macOS Sandbox 内启 server + Chrome MV3 扩展从 `github.com` 上下文 fetch 一次），跑通这条最底层的反向链路再投 M1 全量

---

### 🟧 大问题（按方案施工能做出来，但实际行为会跟描述不符，建议先修订）

#### P1-5：Companion Token 与多账号 DB 隔离冲突

**方案出处**：§2「Token 存储 AES-GCM 加密本地文件 `credentials.json`」、§5.2「Bearer Token 写入 `~/Library/Application Support/Starcat/companion.token`，与 `credentials.json` 同目录」、§9.2 Manifest `storage`。

**实际现状（两层路径不一致）**：

| 资源 | 真实路径 | 隔离粒度 |
|---|---|---|
| `credentials.json`（GitHub Token + AI Key） | `~/Library/Application Support/com.starcat.app/credentials.json` | **应用级单文件（不分账号）** |
| SQLite | `~/Library/Application Support/com.starcat.app/users/<github_user_id>/starcat.sqlite` | **按 GitHub User ID 物理隔离** |

按方案，Companion Token 也放 `credentials.json` 同目录 → 一份 Token 全局共享、跨账号。但插件 `fetch /local/v1/state?fullname=vercel/next.js` 拿到的结果取决于 **App 当前 session 是哪个账号**。

**用户视角的诡异行为**：

> 我明明在 A 账号 star 过 `vercel/next.js`，胶囊为什么显示"未 star"？（因为现在 App 切到了 B 账号 session，B 账号的 SQLite 里没有这条记录）

**方案 §10 / §5 全程没讨论多账号**，得补：

1. 「插件查询返回的 state 永远跟随 App 当前活跃用户」明示
2. 切账号时插件侧缓存如何 invalidate（建议 `/local/v1/state` 响应头返回 `X-Starcat-Active-User: <user_id>`，插件按 user_id 分桶缓存）
3. `/local/v1/state` 没有活跃用户（用户未登录）时的返回（建议 `403` + 提示）

---

#### P1-6：App Sandbox + 嵌入式 HTTP server 的 entitlement 没说

**方案出处**：§5.2 选定方案 A「App 启 `127.0.0.1:5051` HTTP 服务」、§11 M1「3~4 天 实现本地 HTTP 服务模块」、§13 R1「探测 5051~5060 端口」。

**方案漏掉的工程接入点**：

| 项 | 说明 | 工期 |
|---|---|---|
| **`com.apple.security.network.server` entitlement** | Sandbox 默认禁绑 server socket。即使现在直分发，开 Sandbox 后必须显式声明；上 Mac App Store 时审核会问"为什么需要" | entitlement 改 1 分钟，但审核说明文档 0.5 天 |
| **SwiftNIO / Network.framework 选型 + 依赖接入** | Package.swift / xcodegen `project.yml` 改动；SwiftNIO 体积约 5MB，对包大小有影响 | 0.5 天 |
| **Bearer 鉴权 middleware** | 与 `Core/Network/Envelope` 风格对齐（4 后端的 envelope / Bearer 模板） | 1 天 |
| **CORS + PNA 响应头**（见 P0-4） | 与上面 OPTIONS preflight 路径联调 | 0.5 天 |
| **多账号 token 路由**（见 P1-5） | `/local/v1/state` 实现里要先 resolve active user session | 0.5 天 |
| **端口探测 5051~5060** | 启动时遍历探测可用端口，持久化端口号 | 0.5 天 |
| **App 内嵌服务生命周期** | App 后台休眠时 server 是否常驻？休眠时插件 fetch 自动唤起 App？还是直接 503？ | 1 天 |
| **设置页 Companion 分组**（端口 / Token / 状态指示 / 重置按钮） | UI + 状态机 | 1~1.5 天 |

**累计 ≈ 5~7 天**，方案 §11 M1「3~4 天」严重低估。

**建议**：M1 拆成 M1a（HTTP server 基础设施 + entitlement，3 天）和 M1b（设置页 + token 管理 + 多账号路由，2~3 天），并行没有，因为 M1b 依赖 M1a。

---

#### P1-7：F3「未 star 项目隐式 capture + 触发 AI 摘要」有 race + 错误链路缺失

**方案出处**：§4.4 F3「先隐式 capture（与 F2 同款逻辑：enrich + source_types=['clip']）」+「触发 流式生成」、§4.3 F2 关键约束 1「网络不可达时 enrich 失败：`source_types = ['clip']` 仍写入，等下次 sync 自动 enrich」。

**问题链路**：

```
用户点 ✨ (F3) → starcat://summarize?fullname=x/y
   ↓
App 端：本地 DB 没有 x/y
   ↓
隐式 capture：调 GitHub /repos/x/y 拉 metadata
   ↓ ┌─────────────────────────────────────────┐
     │ 失败分支（404 / rate limited / 离线）：     │
     │   F2 约定：仍写 source_types=['clip']       │
     │   但**没有元数据、没有 README**              │
     └─────────────────────────────────────────┘
   ↓
F3 紧接着触发 RepoAIInsightService.generateInsight(repo:)
   ↓
**没 metadata 没 README 怎么摘？**
   → 直接 error
   → 还是生成"该项目无足够上下文"的空话？
```

**方案没明说怎么 fallback**。我倾向：F3 在隐式 capture enrich 失败时直接降级为「只 capture 不摘要 + toast 提示『元数据获取失败，AI 摘要已加入后台队列，待网络恢复后自动生成』」，但需要 dong4j 确认。

**另一隐性假设**：§4.4 关键约束 5 说 `source_hash` 由 「repo 元数据 + README 文本」生成 —— `SemanticSearchService.swift` 已经在用 `snapshot_json`（v2 改造），但 `RepoAIInsightService` 当前 hash 算法我没翻完，**不能想当然**：

- 若现状是仅按 metadata 算 hash → README 还没读完 / README 更新都不会触发重摘
- 若现状是按 metadata + README 内容算 hash → 与方案说法一致

**建议**：开工前 1 小时去读 `RepoAIInsightService.swift` 现状并在方案里明示一句。

---

#### P1-8：Inbox 分类的语义重叠状态没穷举

**方案出处**：§3.1「Inbox 是 Activity 第 9 个子分类，规则=`source_types` 包含 `clip`」、§4.3 关键约束 2「已 star 的 repo 也可重复采集，等于『标记最近浏览过』，更新 `last_seen_at`」、§10 Q10 倾向「提供『从 Inbox 移除』按钮，仅 `source_types -= {clip}` 不连带删主表数据」。

**三态共存（方案没穷举）**：

| 状态 | `is_starred` | `source_types ⊇ {clip}` | 出现在 Inbox 分类 | 胶囊态怎么显示 |
|---|---|---|---|---|
| 只 star | true | false | ❌ | ✓ 已 star |
| 只 clip | false | true | ✅ | ✚ 在 Inbox |
| star + clip | true | true | ✅ | **方案没写**（✓ + ✚？只显 ✓？还是要新设计 Star+Clip 双态徽章？） |
| 都没有 | false | false | ❌ | ☆ 未 star 单一行动按钮 |

**方案 §4.2 胶囊可见性规则表只列了 4 行**，其中**漏掉了 star + clip 双态**。

**`UnifiedRepoRow` 现有 source badge 改造点也没列**：

- Activity weekly 分类的卡片已有 source badge（显示 `WeeklySource` 来源徽章）
- 但 Inbox 分类要不要在卡片上加 "✚ Clip" 徽章？要不要复用 `WeeklySource` 设计成一个新的 `RepoSource.clip`？
- 这个 UI 改造点方案 §8 对接清单完全没提

**建议**：

1. 方案 §4.2 胶囊态表加一行「已 star + 已 clip」
2. §4.3 / §8 加一条改造项「`UnifiedRepoRow` 加 source badge 支持 `clip` 标识」

---

#### P1-9：README 注入位置「最稳定」是乐观估计

**方案出处**：§4.2 F1「README 标题正上方独占一行（容器选 README 上方而非 About 区——README 的 DOM 结构是 GitHub 最稳定的容器之一）」、§13 R3「选最稳定的 README 上方容器；用 `MutationObserver` 容错」、§10 Q2 倾向「README 上方独占一行 DOM 结构最稳定」。

**问题**：

- 2024~2026 之间 GitHub README header 区域至少经历过 3 次结构调整（React 重写 / Anchor 链接调整 / Sticky overlay 容器变更）
- `MutationObserver` 不是 R3 写的「兜底」，是**必备主路径**
- 选 selector 应该用优先级数组而非单一 CSS selector

**建议**：

1. 方案 §13 R3 改写：「`MutationObserver` 是主路径，selector 用优先级数组（README article / README container / `#readme` legacy），全部失败时降级为只在 toolbar popup 显示，不在 GitHub 页面注入」
2. F1 验收标准（§15）加一条「Selector 兼容性 smoke test：在 5 个不同形态的 repo（含 monorepo / 无 README / wiki-only / archived / template）上自动化验证胶囊是否注入成功」

---

### 🟨 小问题（可以工程里再迭代，但开工前最好心里有数）

#### P2-10：工期评估偏乐观（约低估 1~2 周）

| 里程碑 | 方案估时 | 实际偏差原因 | 修订估时 |
|---|---|---|---|
| M1 | 3~4 天 | P1-6 列的 8 项实际累计 5~7 天 | 5~7 天 |
| M2 | 2~3 天 | P0-1 R-04 客户端化（5 天）+ P0-2 DeepLink Router 从 0 搭（2~3 天）+ Activity Inbox（1~2 天） | 7~10 天 |
| M7 | 2~3 天 | 漏掉 Chrome Web Store 商店素材（隐私政策 / 商店截图 / icon / 英文翻译） | 4~5 天 |
| **总计 V0.1** | 3 周 | 按以上修订 | **4~5 周** |

外加 M8 Chrome Web Store 审核 1 周外部时间，**实际首版上线节奏 ≈ 5~6 周**。

---

#### P2-11：多浏览器 + 多 App 实例的边界

**方案出处**：§13 R6「用户开多个浏览器（Chrome + Edge + Arc）；端口共享；Token 一份所有浏览器都能用」。

**正确的部分**：`127.0.0.1` 不区分浏览器，4 个 Chromium 系浏览器共享端口和 Token 是对的。

**方案没覆盖的边界**：

- **同时开两个 Starcat App 实例**（开发者 debug 场景 / 用户误启动两次）：第二个实例绑端口会失败。需要 App 启动时检测已有同 bundle 实例（NSWorkspace API），要么把控制权交给第一个实例（Single Instance）、要么提示用户。
- 这是低频但用户感知很差的场景（"插件突然不工作了，我什么都没改"）。

**建议**：M1 时加一条 "App 启动 single-instance lock，第二个实例 alert + 退出"，零工期占用但避免运维客诉。

---

#### P2-12：§10 未拍板 6 项的施工时机管理

**方案出处**：§10「剩余 Q2 / Q4 / Q6 / Q7 / Q9 / Q10 沿用本方案推荐倾向，开施工时若需调整再开 issue」。

**问题**：

- "施工时若需调整再开 issue" 意味着这些项进入施工后才被发现需要拍板，那时改成本极高（已经写了一半代码）
- 其中 **Q9（反向链路是否走 SSE）** 直接影响 P1-5 多账号切换、AI 摘要完成通知、未读 release 数实时性 —— 用 60s 轮询体验都不及格
- **Q10（Inbox 移除按钮）** 直接影响 P1-8 Inbox 语义穷举

**建议**：开工前把 Q2 / Q4 / Q9 / Q10 升级为必拍板项（Q6 / Q7 可以保持倾向）。

特别地：**Q9 建议升级为 "V0.1 用轮询但 schema_version 里预留 SSE 升级路径"**，避免 V0.2 想加 SSE 时插件侧大改。

---

## 3. 开工前置工作清单

按依赖顺序排，**前 3 项跑通才能投 M1 全量**：

| # | 任务 | 工期 | 负责人 | 产出 |
|---|---|---|---|---|
| 1 | **R-04 客户端化设计稿** | 0.5 天 | dong4j 拍板 + 撰写 | 决定走 P0-1 (a) 扩 `repos` 表 还是 (b) 新建 `clipped_repos` 表，写成新 design doc 提交 PR |
| 2 | **DeepLink Router PoC** | 0.5 天 | studio.cursor | 注册 `.onOpenURL` + 1 个空 action，本机 `open "starcat://test"` App 端打印日志；验证 macOS 唤起链路无 entitlement 卡点 |
| 3 | **PNA + Sandbox server entitlement 最小 demo** | 1 天 | studio.cursor | 50 行 SwiftNIO 在沙盒内启 server + 50 行 Chrome MV3 扩展从 `github.com` 上下文 fetch 一次成功；验证 PNA 响应头组合是否完整 |
| 4 | **§10 未拍板项升级拍板** | 1 小时 | dong4j 拍板 | Q2 注入位置选 selector 优先级数组 / Q4 角标显示未读 release 数 / Q9 升级为 "V0.1 轮询 + 预留 SSE 路径" / Q10 Inbox 移除按钮 V0.1 必做 |

**前置全部完成（约 2 天）后再启动 M1 / M3 全量。**

---

## 4. 方案文档需要修订的具体段落（汇总）

| 方案章节 | 需要修订内容 | 对应问题 |
|---|---|---|
| §2 现状摘要表「Activity 聚合页」行 | "8 个具体分类（含 `discovery`）" → "7 个具体分类（不含 `discovery`，`discovery` 是 `WeeklySource` 来源标签而非 Activity 分类）" | P0-3 |
| §2 现状摘要表「R-04 主表」行 | "客户端已对接" → "**后端已规划，客户端尚未复刻**；本方案前置任务包含 R-04 客户端化设计" | P0-1 |
| §2 现状摘要表「Deep Link」行 | "URL Scheme `starcat://` 已规划但未全量实现" → "URL Scheme 已注册但 **App 端无 handler**，本方案需从 0 搭建 router" | P0-2 |
| §3.1 闭环 A | "Activity 第 9 个子分类" → "Activity 第 8 个子分类"（全文替换） | P0-3 |
| §4.2 F1 胶囊可见性规则表 | 加一行「已 star + 已 clip」状态 | P1-8 |
| §4.3 F2 改造清单 | 明确客户端 schema 改动（依赖 P0-1 设计稿结论）；明确 `UnifiedRepoRow` source badge 加 `clip` 标识 | P0-1 / P1-8 |
| §4.4 F3 关键约束 | 加一条「隐式 capture enrich 失败时 F3 降级为只 capture 不摘要 + toast」；核对 `source_hash` 算法现状 | P1-7 |
| §5.2 反向链路 | 明示 Companion Token 跟随活跃用户 + 切账号缓存 invalidate；`/local/v1/state` 响应头加 `X-Starcat-Active-User` | P1-5 |
| §9.2 Manifest 权限 + §13 R2 | CORS 改写为 PNA，三响应头组合：`Allow-Origin` / `Allow-Private-Network` / `Allow-Headers: Authorization` | P0-4 |
| §11 工期表 | M1 改 5~7 天；M2 改 7~10 天；M7 改 4~5 天；总工期改 4~5 周 | P2-10 |
| §13 R3 | `MutationObserver` 是主路径而非兜底；selector 用优先级数组 | P1-9 |
| §13 R6 | 补「App 启动 single-instance lock」 | P2-11 |
| §10 Q9 | 倾向改为「V0.1 轮询但 schema_version 预留 SSE 升级路径」 | P2-12 |
| §10 Q10 | 倾向改为「V0.1 必做 Inbox 移除按钮」（依赖 P1-8 三态语义） | P2-12 / P1-8 |
| §15 验收标准 | 加「Selector 兼容性 smoke test 在 5 个不同形态 repo 验证」/ 加「PoC 已跑通 PNA」/ 加「多账号切换不串数据」 | P0-4 / P1-5 / P1-9 |

---

## 5. 附录：代码现状速查表（评审凭据，供后续 reviewer 复核）

### 5.1 数据库 schema 现状

- 文件：`Starcat/Starcat/Core/Database/Migrations/DatabaseMigrationsV1.swift`
- 关键事实：
  - 单一 v1-initial 摊平所有表，**没有** `github_repos` / `clipped_repos` / `source_types` 列 / `last_seen_at` 列
  - 实际表：`repos`（28 列含 `is_starred`） / `starred_repos` / `tags` / `repo_tags` / `repo_notes` / `readmes` / `saved_searches` / `sync_state` / `tag_stats_cache` / `repos_fts` / `trending_repos` / `trending_readmes` / `repo_embeddings` / `ai_summaries` / `release_subscriptions` / `releases` / `readme_translations`
  - dong4j 决策（2026-06-11）：产品上线前一律改 v1，**不写 ALTER**

### 5.2 Activity 分类现状

- 文件：`Starcat/Starcat/Features/Activity/ActivityModels.swift`
- 关键事实：
  - `ActivityCategory` 共 **8 个 case**：`all / announcement / release / star / repository / following / suggestion / weekly`（`all` 是"全部"聚合视图，实际可独立分类是 7 个）
  - **不含 `discovery`**
  - `weekly` 是 MUL-176 阮一峰周刊集成（远端独立 API）
- 文件：`Starcat/Starcat/Core/Network/WeeklyModels.swift`
- 关键事实：
  - `WeeklySource` enum：`weekly / zread / discovery / unknown(String)` —— 这是 **starcat-weekly-api** 的 DTO 字段，不是 Activity 分类

### 5.3 URL Scheme 现状

- 文件：`Starcat/Starcat/Generated/Info.generated.plist`
- 关键事实：
  - 注册了 `CFBundleURLSchemes = ["starcat"]`，URLName = `com.starcat.app`
- 文件：`Starcat/Starcat/Shared/Utilities/Constants.swift`
- 关键事实：
  - 定义了 `oauthCallbackURL = "starcat://callback"` 但 **OAuth 实际用 Device Flow**（`GithubDeviceFlowService.swift`），callback 链路从未启用
- 全工程 grep 结果：
  - `onOpenURL` → 仅在 `SearchCenterView` / `RepoMetadataHeaderView` 等业务内场景使用，**未应用于 URL Scheme handler**
  - `kAEInternetEventClass` / `NSAppleEventManager` → 0 命中

### 5.4 凭证存储现状

- 文件：`Starcat/Starcat/Core/Keychain/KeychainManager.swift`
- 关键事实：
  - 单一 `credentials.json`，AES-GCM 加密（CryptoKit）
  - 路径：`~/Library/Application Support/com.starcat.app/credentials.json`（**应用级单文件，不分账号**）
  - 与 SQLite 路径 `~/Library/Application Support/com.starcat.app/users/<github_user_id>/starcat.sqlite`（**按账号隔离**）不同源

### 5.5 AI 摘要服务现状

- 文件：`Starcat/Starcat/Features/AI/RepoAIInsightService.swift` / `RepoAIWindowController.swift` / `RepoAIInsightViewModel.swift` / `RepoAIChatViewModel.swift`
- 关键事实：
  - 服务存在且支持流式摘要 + 标签推荐 + JSON mode + 缓存命中（具体 hash 算法见 P1-7 待核对）
  - `RepoAIWindowController` 已有 AI 浮窗实现，F3 可直接复用
  - `SemanticSearchService.swift` v2 已切到 `snapshot_json` hash 策略（但 `RepoAIInsightService` 是否同步切换未核对）

### 5.6 StarredRegistry / Repository 现状

- 文件：`Starcat/Starcat/Core/Sync/StarringSubsystem.swift`
- 关键事实：
  - `@MainActor @Observable` 单一信任源 ✅（方案描述准确）
  - 数据结构 `Set<Int64>` of `gh_repo_id` ✅
  - O(1) 查询 + 毫秒级全量加载（1810 行实测） ✅

---

## 6. 历史

| 日期 | 修订 | 触发 |
|---|---|---|
| 2026-06-14 | 初版（v1.0），整理 [HOM-197](mention://issue/c8e10c21-5e72-4e51-b95a-966b1f3eea6f) 评审结论 | dong4j 要求把 studio.cursor 整理的 12 项问题落档到方案同目录 |
