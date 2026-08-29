# UI 颜色规范:适配明暗主题

> **强制,2026-06-14 起生效**
> 来源：早期从根协作规范沉淀到本目录；现行维护源为根 `AGENTS.md`。`AGENTS.md` 只保留引用链接，不重复正文。

---

## 规则

文字 / 图标 `foregroundStyle` **只用 `.primary` 或 `.secondary`,禁止 `.tertiary`**。

`.tertiary` 在浅色主题下对比度仅约 1.5:1(远低于 WCAG AA 4.5:1),文字图标在白底上几乎"灰糊"不可读。

## 唯一例外

刻意弱化的装饰性图标占位(如队列未开始态 `Image("circle")`、未选中态视觉降级等),可以保留 `.tertiary`,但**必须**在代码注释里写明"故意弱化 + 产品意图"。

## 适用场景

- 所有 `Text` 视图的文字色
- 所有 `Label` / `Button` 的图标色
- 所有 `Image` 渲染模式下的前景色

## 反例(必须避免)

```swift
// ❌ 错误写法
Text("状态")
    .foregroundStyle(.tertiary)

// ✅ 正确写法
Text("状态")
    .foregroundStyle(.secondary)
```

## 自检

```bash
rg "\.tertiary" --type swift Starcat/  # 只能出现在带"故意弱化"注释的代码里
```
