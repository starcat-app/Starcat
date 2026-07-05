# UI 规范:危险操作图标

> **强制,2026-07-05 起生效**
> 来源:Activity 清空入口视觉不一致问题沉淀。`DESIGN.md` 保留整体视觉语言,本文件约束具体危险操作入口。

---

## 规则

**所有** toolbar / filter bar / inline 工具区里的 icon-only 删除或清空入口,必须使用无背景的系统图标按钮。

```swift
DestructiveIconButton(help: Text("activity.announcement.clear.help")) {
    showConfirm = true
}
```

## 视觉规格

- SF Symbol:`trash`
- 字号:`SyncIconButton.defaultFont`
- 占位:`SyncIconButton.defaultFrameSize`
- 默认颜色:`.secondary`
- 默认无背景;不要用胶囊底、圆形底或红色底
- 必须 `.buttonStyle(.plain)` + `.focusEffectDisabled()`
- 必须有 `.help(...)`
- 必须先弹确认对话框,不能直接执行不可逆删除 / 清空

## 颜色语义

工具区入口默认不使用红色。红色 / destructive role 留给确认弹窗里的最终确认按钮,避免页面长期出现高警示色并干扰阅读。

## 不适用

- 带文字的 destructive 按钮,例如确认弹窗中的 `Button(..., role: .destructive)`
- Sheet / 表单里的完整危险操作按钮
- 非删除语义的取消按钮,例如任务运行中的 `xmark.circle.fill`

## 提交前自检

```bash
# 新增 toolbar / filter bar / inline 删除入口时,检查是否仍有默认 Button 背景或不一致字号
rg 'Image\\(systemName: "trash"\\)' --type swift Starcat/
```
