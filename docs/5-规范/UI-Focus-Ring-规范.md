# UI 规范:Focus Ring 蓝框

> **强制**
> 来源:从 `CLAUDE.md` 沉淀到本目录。`CLAUDE.md` 保留引用链接,不重复正文。

---

## 规则

**所有**使用 `.buttonStyle(.plain)` 的 Button **必须**添加 `.focusEffectDisabled()`,禁用 macOS 默认的蓝色 focus ring。

> ⚠️ 这是强制规则。任何新建或修改的 Button 若遗漏 `.focusEffectDisabled()`,必须补上。

```swift
// ✅ 正确写法
Button { ... }
    .buttonStyle(.plain)
    .focusEffectDisabled()  // ← 强制,放在 buttonStyle 之后

// ❌ 错误写法:缺少 focusEffectDisabled(会显示蓝框)
Button { ... }
    .buttonStyle(.plain)
```

## 适用场景(包括但不限于)

- 侧边栏折叠/展开按钮(chevron)
- 登录/注册页面、OAuth 流程所有按钮
- 右上角关闭按钮(xmark.circle.fill)
- 搜索栏展开/收起按钮
- 工具栏图标按钮(sync、filter、sort 等)
- Tags 管理相关按钮(+、编辑、删除)
- 任何自定义图标的装饰性/操作性按钮

## 新增 Button 时的检查流程

1. 若使用 `.buttonStyle(.plain)` → 必须紧跟 `.focusEffectDisabled()`
2. 提交前用 `grep -n "buttonStyle.plain" --include="*.swift" .` 检查该文件是否遗漏

## 参考组件

- `Starcat/Shared/Components/SheetCloseButton.swift`(已内嵌)
- `Starcat/Shared/Components/SyncIconButton.swift`(已内嵌)
