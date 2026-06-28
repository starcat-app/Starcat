# UI 规范:刷新图标

> **强制,2026-06-26 起生效**
> 来源:从 `CLAUDE.md` 沉淀到本目录。`CLAUDE.md` 保留引用链接,不重复正文。

---

## 规则

**所有**「刷新 / 重新拉取 / 同步列表」类 **icon-only 触发器** 必须走 `SyncIconButton`(`Starcat/Shared/Components/SyncIconButton.swift`),禁止各 surface 自绘 `arrow.clockwise` 或 loading 时换成 `ProgressView`。

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

## 视觉与动效规格

- SF Symbol:`arrow.triangle.2.circlepath`(与 Manage「同步于」旁、Sidebar「仓库分组」刷新同款)
- **静止**:`.foregroundStyle(.secondary)`
- **刷新中**:`.foregroundStyle(.accentColor)` + 线性 1s `repeatForever` 旋转(组件内 `rotationEffect` 实现)
- **禁止**用 `ProgressView` 替代旋转中的图标
- **禁止**用 `.symbolEffect(.rotate, value:)` / `.symbolEffect(.variableColor)` 做刷新动效(行为与预期不符,见 `SyncIconButton.swift` 文件头)

## 特殊场景

- Manage 顶栏 **Stars 全量同步**(含 hover 取消 / rate limit):用 `StarsSyncButton`(内部同款图标与旋转;同步中同样变 `.accentColor`)
- 带文字的刷新行(如 Release「立即检查」):图标仍用 `arrow.triangle.2.circlepath`,静止 `.secondary`、进行中 `.accentColor` + 旋转,与 `SyncIconButton` 同色同动效

## 不适用

- 菜单项 `Label(..., systemImage: "arrow.clockwise")` 的「重新生成 / 恢复购买」等 **文案动作**(非 icon-only 刷新触发器)
- 账户菜单「刷新个人信息」

## 反例(必须避免)

- ❌ `arrow.clockwise` 做列表 / toolbar / sheet header 刷新
- ❌ 刷新中只变 `ProgressView`、图标不转、不变蓝
- ❌ 各页面 refresh 图标大小 / 颜色 / 动效不一致

## 参考实现

- `SidebarView`(仓库分组)
- `RepoListView`(同步于)
- `ActivityView`
- `TrendingView`
- `WeeklyContentView`
- `RepoHealthSheet`
- `SmartSearchField`(语义索引刷新)

## 提交前自检

```bash
# 刷新触发器不应再引入 arrow.clockwise(菜单 Label 除外,须注释说明非刷新触发器)
rg 'arrow\.clockwise' --type swift Starcat/Features/
```
