# UI 规范:禁止 Stepper

> **强制,2026-06-20 起生效**
> 来源:从 `CLAUDE.md` 沉淀到本目录。`CLAUDE.md` 保留引用链接,不重复正文。

---

## 规则

**禁止**在新 UI 中使用 SwiftUI `Stepper` 组件。

数值输入一律用 `TextField` + 数字过滤 + 范围钳制(参考 `MCPSettingsView.mcpPortTextBinding`、`SearchCenterView.anySearchMaxResultsTextBinding`)。

范围较大或需要连续调节时用 `Slider`(参考 `AISettingsView` 阈值滑杆)。

## 反例(必须避免)

- ❌ `Stepper(value:in:step:)` 调端口 / 结果数 / 行数
- ✅ `TextField` + binding 内 `filter(\.isNumber)` + `min(max(...))`

## 提交前自检

```bash
rg "Stepper\(" --type swift Starcat/   # 新增代码不应再引入 Stepper
```
