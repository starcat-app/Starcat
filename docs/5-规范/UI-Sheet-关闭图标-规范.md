# UI 规范:Sheet 关闭图标

> **强制,2026-06-26 起生效**
> 来源：早期从根协作规范沉淀到本目录；现行维护源为根 `AGENTS.md`。`AGENTS.md` 只保留引用链接，不重复正文。

---

## 规则

**所有**自定义 sheet / 浮层 / 面板 **header 右上角「关闭」** 必须走共享组件 `SheetCloseButton`(`Starcat/Shared/Components/SheetCloseButton.swift`),禁止各调用点手写样式。

```swift
// ✅ 正确写法
SheetCloseButton { dismiss() }

// 各 surface 尺寸不同:通过参数保留原占位,禁止改图标语义
SheetCloseButton(
    action: { dismiss() },
    iconFont: .system(size: 16, weight: .medium),
    frameSize: 26,
    helpKey: "common.close"
)
```

## 视觉规格(单一信任源)

- SF Symbol:`xmark.circle.fill`
- `.symbolRenderingMode(.hierarchical)` + `.foregroundStyle(.secondary)`(明暗主题自动适配)
- `.buttonStyle(.plain)` + `.focusEffectDisabled()`(组件内已封装)

## 不适用(禁止误用 `SheetCloseButton`)

- 搜索框「清空内容」(语义是 clear,不是 close sheet)
- destructive 红叉(如删除确认、错误态)
- `StarsSyncButton` 同步中 hover 取消(`xmark.circle.fill` 有特殊交互语义)
- 标签墙「清除选中」等 filter 清除操作

## 反例(必须避免)

- ❌ 裸 `xmark`(无圆形底,hit area 与 macOS dismiss 惯例不一致)
- ❌ `xmark.circle.fill` 不设 `hierarchical` / `secondary`(浅色主题下会变成实心黑圆,过重)
- ❌ `.buttonStyle(.bordered)` 灰底关闭钮

## 参考实现

- `RepoHealthSheet`
- `GitHubStarListEditorSheet`
- `ShareCardSheet`
- `RepoAIWindowContentView`

## 提交前自检

```bash
# 新增 sheet header 关闭应出现 SheetCloseButton,而非裸 xmark
rg 'Image\(systemName: "xmark"\)' --type swift Starcat/Features/
```
