# UI 规范:刷新图标

> **强制,2026-06-26 起生效**；点击确认反馈与最短可见时长条款于 **2026-07-29** 补齐。
> 来源：早期从根协作规范沉淀到本目录；现行维护源为根 `AGENTS.md`。`AGENTS.md` 只保留引用链接，不重复正文。
> 实现单一入口:`Starcat/Shared/Components/SyncIconButton.swift`

---

## 规则

**所有**「刷新 / 重新拉取 / 同步列表」类 **icon-only 触发器** 必须走 `SyncIconButton`,禁止各 surface 自绘 `arrow.clockwise` 或 loading 时换成 `ProgressView`。

```swift
// ✅ 正确写法(尺寸按原占位传入 font / frameSize)
SyncIconButton(
    isRefreshing: viewModel.isRefreshing,
    disabled: viewModel.isRefreshing,
    font: .caption,
    frameSize: 18,
    tooltip: String.l10n("activity.refresh")
) {
    Task { await viewModel.refresh() }
}
```

---

## 视觉与动效规格

- SF Symbol:`arrow.triangle.2.circlepath`(与 Manage「同步于」旁、Sidebar「仓库分组」刷新同款)
- **静止**:`.foregroundStyle(.secondary)`
- **刷新中 / 点击确认中**:`.foregroundStyle(.accentColor)` + 线性 **1 秒/圈** `repeatForever` 旋转(组件内 `rotationEffect` 实现)
- **禁止**用 `ProgressView` 替代旋转中的图标
- **禁止**用 `.symbolEffect(.rotate, value:)` / `.symbolEffect(.variableColor)` 做刷新动效(行为与预期不符,见 `SyncIconButton.swift` 文件头)

---

## 点击反馈(强制)

手动点击刷新后,**必须**有可见的变蓝 + 转圈反馈。不得出现「点了完全没反应」。

覆盖两类情况:

| 情况 | 要求 |
|------|------|
| **真实刷新** | `isRefreshing=true` 期间持续转圈;结束后仍须满足下方「最短可见时长」 |
| **未发起 / 被门控拒绝** | 冷却未到、去重拦截、未登录等导致**本次不拉网**时,仍须变蓝并至少转 **完整 1 圈**(≥ 1s),表示点击已被接收 |

> ⚠️ 「冷却未到也要转一圈」与「请求极快也要转够最短时长」是同一产品原则的两端:前者解决门控吞点击,后者解决返回太快看不见。

### 职责边界

- **`SyncIconButton`**:只根据 `isRefreshing` 驱动变蓝与旋转;提供 `minVisibleDuration`(默认应 ≥ 1s,与「完整一圈」对齐)。不负责业务冷却逻辑。
- **Caller / ViewModel**:决定是否真正拉网;若点击被冷却等门控拒绝,**仍须短暂拉高** `isRefreshing`(或走统一的 acknowledgement API),让按钮完成至少一圈确认反馈。禁止在 `action` 里静默 `return` 且不触动 `isRefreshing`。
- **禁止**各页面自写第二套空转 / 闪蓝动画绕过 `SyncIconButton`。

### 最短可见时长

即便真实刷新在几毫秒内结束,按钮仍须至少保持转圈 **`minVisibleDuration`**(默认 **1s** = 完整一圈)。  
`SyncIconButton` 内部用 `enforcedRefreshing` 状态机实现;调用方只需保证「进入刷新时 `isRefreshing` 至少闪过 true」。

特殊场景可显式传 `minVisibleDuration: 0` 关闭兜底(须在调用处注释原因)。

---

## 适用范围

本规范为**全项目**强制原则。  
仓库洞察(Repository Insights)页内全部手动刷新入口须完整落地(活动概览 / 提交活动 / Star 历史 / 顶栏全局刷新及同页其它 Sync)。其它 surface 新建或改动刷新时同步对齐;存量入口发现「点了没反馈」按本规范修。

---

## 特殊场景

- Manage 顶栏 **Stars 全量同步**(含 hover 取消 / rate limit):用 `StarsSyncButton`(内部同款图标与旋转;同步中同样变 `.accentColor`)
- 带文字的刷新行(如 Release「立即检查」):图标仍用 `arrow.triangle.2.circlepath`,静止 `.secondary`、进行中 `.accentColor` + 旋转,与 `SyncIconButton` 同色同动效;若存在冷却门控,同样遵守「未拉网也要至少一圈」

---

## 不适用

- 菜单项 `Label(..., systemImage: "arrow.clockwise")` 的「重新生成 / 恢复购买」等 **文案动作**(非 icon-only 刷新触发器)
- 账户菜单「刷新个人信息」

---

## 反例(必须避免)

- ❌ `arrow.clockwise` 做列表 / toolbar / sheet header 刷新
- ❌ 刷新中只变 `ProgressView`、图标不转、不变蓝
- ❌ 冷却未到 / 门控拒绝时静默吞点击,图标无任何反馈
- ❌ 各页面 refresh 图标大小 / 颜色 / 动效不一致
- ❌ 页面自绘「空转一圈」绕过 `SyncIconButton`

---

## 参考实现

- `SyncIconButton`(共享组件 + `minVisibleDuration` / `enforcedRefreshing`)
- `SidebarView`(仓库分组)
- `RepoListView`(同步于)
- `ActivityView`
- `TrendingView`
- `WeeklyContentView`
- `RepoHealthSheet`
- `SmartSearchField`(语义索引刷新)
- `RepositoryInsightsView`(仓库洞察各区块刷新)

---

## 提交前自检

```bash
# 刷新触发器不应再引入 arrow.clockwise(菜单 Label 除外,须注释说明非刷新触发器)
rg 'arrow\.clockwise' --type swift Starcat/Features/

# 手动刷新若有冷却 / guard,确认拒绝路径仍会拉高 isRefreshing(或等价 acknowledgement)
rg 'reserveManualRefresh|manualRefreshCooldown' --type swift Starcat/
```
