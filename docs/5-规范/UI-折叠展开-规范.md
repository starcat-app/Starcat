# UI 规范：折叠/展开整行点击

> **强制，2026-07-13 起生效**

---

## 规则

所有折叠/展开组件的**标题行必须整行可点击**。chevron 仅用于表达当前展开状态，不能成为唯一的点击触发区。

标题行应使用完整的 `Button` 承载切换动作，并覆盖可见行宽：

```swift
Button {
    isExpanded.toggle()
} label: {
    HStack {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        Text("标题")
        Spacer()
    }
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
.focusEffectDisabled()
```

## 交互约束

- 点击标题、空白区域或 chevron 都必须切换展开状态。
- chevron 不应单独包裹为 Button；它是标题行 Button 的视觉子元素。
- 标题行内有复制、删除、菜单等独立操作时，这些操作保留各自点击区，不能误触发展开。
- 禁止直接使用 macOS 默认交互的 `DisclosureGroup` 作为标题行；它可能只允许点击 chevron。若使用 `DisclosureGroup` 承载内容，label 必须改为符合本规范的整行 Button。
- 使用 `.buttonStyle(.plain)` 时，必须遵循 [`UI-Focus-Ring-规范.md`](UI-Focus-Ring-规范.md) 添加 `.focusEffectDisabled()`。

## 参考实现

- `Starcat/Features/Releases/ReleaseTimelineView.swift` 的 `disclosureRow`
- `Starcat/Features/Settings/AISettingsView.swift` 的 `disclosureLabel`
- `Starcat/Features/RAG/UI/KnowledgeRAGWorkspaceView.swift` 的调试记录折叠行

## 提交前自检

```bash
rg 'DisclosureGroup|chevron\\.(right|down)' --type swift Starcat/
```

逐项确认标题行不是仅 chevron 可点击；新增或修改的 plain Button 必须带 `.focusEffectDisabled()`。
