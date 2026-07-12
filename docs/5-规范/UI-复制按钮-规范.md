# UI 规范：复制按钮反馈

> **强制，2026-07-12 起生效**

## 规则

新增或调整的复制按钮必须复用 `CopyFeedbackButton`，禁止页面自行调用 `NSPasteboard` 后不提供反馈。

复制成功后，按钮在 1.5 秒内必须显示绿色 `checkmark.circle.fill`；`CopyFeedbackButton` 会统一注入 SF Symbol 切换动画。应用开启“减少动态效果”时，组件自动跳过状态与图标动画。连续点击必须取消旧复位任务并重新计时。

## 用法

```swift
CopyFeedbackButton(
    providesContent: { value },
    tooltip: "settings.example.copy"
) { didCopy in
    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
        .foregroundStyle(didCopy ? Color.green : .secondary)
}
```

已有表单边框的复制入口使用 `style: .bordered`，其余入口保持默认 `.plain`；两种样式均由组件统一禁用 focus ring。
