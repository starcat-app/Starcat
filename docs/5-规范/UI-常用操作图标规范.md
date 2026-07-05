# UI 规范:常用操作图标

> **强制,2026-07-05 起生效**
> 来源:关闭 / 刷新 / 重置 / 删除图标多处视觉不一致问题沉淀。`DESIGN.md` 保留整体视觉语言,本文件约束常用操作入口。

---

## 规则

常用 icon-only 操作必须优先使用共享组件,不要在页面里重复手写字号 / frame / focus ring。

| 语义 | 共享入口 | SF Symbol | 默认规格 |
|---|---|---|---|
| 关闭 sheet / 面板 | `SheetCloseButton` | `xmark.circle.fill` | hierarchical + `.secondary` |
| 刷新 / 同步 | `SyncIconButton` | `arrow.triangle.2.circlepath` | `.secondary`;刷新中 `.accentColor` + 旋转 |
| 删除 / 清空 | `DestructiveIconButton` | `trash` | `SyncIconButton.defaultFont/defaultFrameSize` |
| 重置 / 恢复默认 | `ResetIconButton` | `arrow.counterclockwise` | `SyncIconButton.defaultFont/defaultFrameSize` |
| 主 toolbar 图标 | `ToolbarIcon` | 按语义传入 | `ToolbarIconMetrics` |

## 不要混用

- `SheetCloseButton` 只表示关闭 sheet / 面板,不表示清空输入、移除标签、关闭 toast。
- `SyncIconButton` 只表示 icon-only 刷新 / 同步触发器;菜单里的“重新生成”可以保留 `Label(..., systemImage:)`。
- 删除 / 清空入口默认不使用红色;红色留给确认弹窗里的 destructive 按钮。
- 重置入口是恢复默认值,不是重新拉取远端数据;重新拉取应使用 `SyncIconButton`。

## 提交前自检

```bash
rg 'Image\\(systemName: "(trash|arrow.counterclockwise|arrow.triangle.2.circlepath)"\\)' --type swift Starcat/
rg 'Image\\(systemName: "xmark"\\)' --type swift Starcat/Features/
```
