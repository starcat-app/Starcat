# Starcat OpenSSF Scorecard 集成方案（需求初稿）

> 状态：v0 初稿（2026-06-16 起草），未拍板。
>
> 讨论上下文：
> - dong4j 提出需求：在 repo 卡片展示 OpenSSF 评分，详情页提供雷达图入口
> - 关键约束：仅对已 star 的 repo 处理、404 也需落库避免重复打网络、TTL 7 天
> - 数据源：`https://api.securityscorecards.dev/projects/github.com/{owner}/{repo}`（公开、无鉴权）

---

## 目标

在 Starcat 中接入 **OpenSSF Scorecard**（Linux Foundation 旗下，由 Google 安全团队维护的开源仓库安全评估项目）的公开 API，给每个已 star 的 repo 附加一个"安全健康度"信号。

UI 形态：

- **Repo 列表卡片**：右侧小徽章（圆点 + 数字），有数据时显示，无数据时**整块不渲染**（不显示"暂无"占位）
- **详情页**：侧栏加按钮，点击弹出**雷达图视图**，基于 18 维 JSON 自行渲染

非目标（明确不做）：

- ❌ Dependabot alerts / Code scanning alerts / Secret scanning alerts（必须仓库写权限，star 场景不可用）
- ❌ 全球 repo 评分排行榜
- ❌ 评分历史趋势图
- ❌ 自定义雷达图维度权重

---

## 数据源澄清

调研确认（2026-06-16 实测）：

| 数据源 | 可用性 |
|---|---|
| `/repos/{o}/{r}` 的 `security_and_analysis` / `vulnerability_alerts` | ❌ 对非协作者返回 `null` |
| `/repos/{o}/{r}/security-advisories` | ✅ 公开，但 CopilotKit 这类 0 条时无意义 |
| `/dependency-graph/snapshots` | ❌ 非协作者拿不到 |
| **`api.securityscorecards.dev`** | ✅ **公开、无鉴权、无调用次数上限、CC-BY 4.0 许可** |
| OpenSSF Scorecard 完整 JSON 大小 | ~7KB ~ 50KB / repo |

**重要约束**：OpenSSF 不是所有 repo 都被索引（CopilotKit 当前 404），UI 必须**优雅降级**。

---

## 数据模型（1 张表）

```
openSSFScore (1:1 with repo)
├─ repoId           : Int64   PK FK → 已有 repo 表
├─ fetchStatus      : enum   // success / notIndexed / networkError / parseError
├─ aggregateScore   : Double? // 总分,可能为 nil（未拉取成功 / 数据缺失）
├─ checksJSON       : BLOB    // 完整 18 维 JSON,直接存原始 payload
├─ scoreDate        : Date?   // OpenSSF 返回的 date 字段（数据本身的时效）
├─ fetchedAt        : Date    // 本地拉取时间（用于 TTL 判断）
└─ lastError        : String? // 失败原因,可空,用于调试
```

**关键字段说明**：

- `scoreDate` 与 `fetchedAt` 含义不同：前者是 OpenSSF 跑分时间，后者是 Starcat 拉到这份数据的时间
- `fetchStatus` 区分**永久性失败**（`notIndexed`，对应 404）与**临时性失败**（网络错、解析错），二者重试策略不同
- `aggregateScore` 为 `nil` 的两种合法场景：从未拉取成功 / OpenSSF 数据本身缺总分

---

## 数据流（3 个入口）

### 入口 1：后台任务

```
NSBackgroundActivityScheduler（每日触发 1 次）
  → 遍历 starred repo 且满足 "需要刷新" 条件
  → 调 OpenSSF API（限流 5 req/s）
  → 写 DB
```

**"需要刷新"条件**：

- `fetchStatus = success` 且 `fetchedAt` > 7 天前
- `fetchStatus = notIndexed` 且 `fetchedAt` > 30 天前（永久 404 也别反复打）
- `fetchStatus = networkError` 且 `fetchedAt` > 1 天前（指数退避）
- `fetchStatus = parseError` 且 `fetchedAt` > 1 天前

**核心约束**：

- 只对 `is_starred = true` 的 repo 处理（star 之外的 repo 不消耗 API 配额）
- 后台任务**限流 3 并发 + 5 req/s**
- 单次任务超时立刻放弃，下次再跑

### 入口 2：详情页打开（用户主动触发）

```
详情页 ViewModel.init(repoId)
  → 读 DB
  ├─ 命中缓存（success + fetchedAt < 7d）→ 立即展示
  │     → 异步 SWR：后台悄悄刷新一次（Stale-While-Revalidate）
  ├─ 缓存过期 / 首次（fetchedAt > 7d 或从未拉取）
  │     → 立即显示 loading → 拉 API → 写 DB → 更新 UI
  └─ fetchStatus = notIndexed（且 fetchedAt < 30d）
        → 直接展示 "暂无评估数据"，不发起网络请求
```

**Stale-While-Revalidate**：展示旧数据的同时后台刷新，避免用户每次打开详情页都要等网络。

### 入口 3：列表渲染（**严格只读 DB**）

```
ListCell.render(repoId)
  → 同步读 DB（GRDB fetchOne）
  ├─ fetchStatus = success + aggregateScore != nil → 显示小徽章
  └─ 其它 → 整块不渲染
```

**硬约束**：**列表渲染永远只读 DB，绝不打网络**。保证滚动 60fps。

---

## UI 设计要点

### 列表小徽章

```
┌──────────────────────────────────┐
│ ⭐ vuejs/core                     │
│ Reactive, encapsulated...         │
│                                  │
│            🟢 6.4  ← 新增,右对齐  │
└──────────────────────────────────┘
```

- 仅在 `aggregateScore` 有效时显示
- 颜色梯度：≥ 7.5 绿 / 5-7.5 黄 / < 5 红
- 整个徽章**可点击**，点击进入详情页雷达图（同侧栏按钮行为）

### 详情页按钮 + 雷达图

- 侧栏按钮：「安全评估」标签
- 点击弹出 sheet（覆盖详情页右侧），内含：
  - 顶部：聚合分数 + 数据日期 + "刷新"按钮（手动绕过 TTL）
  - 主体：**自绘 Canvas 雷达图**（18 维，过滤掉 -1 "无法评估"项）
  - 底部：每个维度的明细列表（名称 + 分数 + reason 文案）

### 雷达图渲染

- **自绘 SwiftUI Canvas**：~200 行代码，极坐标转直角坐标画多边形
- **Swift Charts 不推荐**：macOS 13+ RadarMark 需 workaround，且不能完全控制样式
- **过滤 -1**：数据不足的维度**不参与画图**，UI 标注"无法评估"而不是"得 -1 分"

---

## 我补充的几条（dong4j 没想到但应该考虑的）

1. **fetchStatus 区分 404 / 网络错 / 解析错** —— 重试策略完全不同
2. **Stale-While-Revalidate** —— 详情页打开时展示旧数据的同时后台刷新，体感"秒开"
3. **404 冷却 30 天** —— CopilotKit 这种永久 404 别每 7 天都去打一次
4. **后台限流** —— OpenSSF 没说上限，但 3 并发 + 5 req/s 是 polite 做法
5. **-1 分数剔除** —— 雷达图不画 "负分"，也不计入总分聚合
6. **`fetchedAt` 仅在 success 时重置** —— 失败调用不刷新 TTL，避免反复打坏端点
7. **国际化** —— "安全评估"、"暂无评估数据"、"X 天前更新" 等字符串全走 String Catalog（zh-Hans + en）
8. **关于页致谢** —— OpenSSF 集成进 Starcat 了，**必须**在 `AboutView.swift` 的 `AboutDependency.all` 加一条（Apache 2.0 + Linux Foundation 版权行）
9. **单测 mock** —— 用项目已有的 `URLProtocolStub.swift` 模式 mock OpenSSF API，**必须**覆盖：成功 / 404 / 网络错 / JSON 损坏 四种 case
10. **存储开销** —— 18 checks × ~50 字节 ≈ 1KB / repo，1000 starred repo ≈ 1MB，**完全可接受**

---

## 待 dong4j 拍板的开放问题

| # | 问题 | 默认建议 |
|---|---|---|
| Q1 | 雷达图弹窗形态 | sheet（覆盖详情页右侧） |
| Q2 | 首次安装是否触发 warmup | 否，让用户点详情页按需触发 |
| Q3 | 是否提供 "强制刷新" 按钮 | v1 不做，需要时再加 |
| Q4 | 后台任务频率 | 每天 1 次 |
| Q5 | 并发上限 | 3 并发 + 5 req/s 节流 |
| Q6 | 雷达图最大展示维度 | 全部 18 项，不折叠（即使 -1 也单独标"无法评估"） |
| Q7 | 列表徽章颜色阈值 | ≥7.5 绿 / 5-7.5 黄 / <5 红（与 GitHub 风险色一致） |

---

## 不做的事（再次明确）

- ❌ 不接 Dependabot alerts / Code scanning alerts / Secret scanning alerts（必须仓库写权限）
- ❌ 不做 OpenSSF 之外的安全数据源（不引入 Snyk / Sonatype 等第三方）
- ❌ 不做"安全评分排行榜"或"全局 repo 评分筛选"
- ❌ 不做"OpenSSF 评分变化通知"
- ❌ 不做"自定义雷达图权重"

---

## 升级路径

如果 v1 落地顺利，后续可扩展：

- v1.1：引入 **GitHub Advisory DB 自建 Dependabot**（拉 manifest 文件 → 匹配 CVE），与 OpenSSF 互补
- v1.2：在雷达图页加"该 repo 命中 CVE 数"小角标
- v1.3：组合评分（OpenSSF Scorecard × 0.4 + Advisory 命中扣分 × 0.6）作为综合"安全分"

---

## 参考链接

- OpenSSF 官网：https://openssf.org/
- OpenSSF Scorecard GitHub：https://github.com/ossf/scorecard
- 18 维检查项定义：https://github.com/ossf/scorecard/blob/main/docs/checks.md
- 公开 API：https://api.securityscorecards.dev/
- 可视化页面：https://scorecard.dev/viewer/?uri=github.com/{owner}/{repo}
- 实测数据样本：
  - vuejs/core：https://api.securityscorecards.dev/projects/github.com/vuejs/core
  - nodejs/node：https://api.securityscorecards.dev/projects/github.com/nodejs/node
- Starcat 相关文档：
  - 主进度索引：`docs/工程进度/功能实现总览.md`
  - 第三方资源记录：`docs/第三方资源使用记录.md`
  - i18n 规范：CLAUDE.md 内"国际化规范"小节
  - 开源致谢规范：CLAUDE.md 内"开源致谢同步规则"小节