# UI 规范：Sheet 尺寸与承载

> **强制，2026-08-29 起生效**
> 全局视觉语言以 [`DESIGN.md`](../../DESIGN.md) 为准；本规范只定义 macOS Sheet 的尺寸所有权、承载方式与性能边界。

---

## 1. 核心原则

先判断“谁拥有窗口尺寸”，再选择实现：

- **内容拥有尺寸**：内容短小、结构简单，窗口应跟随表单自然高度时，使用 SwiftUI 自动 `.sheet`。
- **产品拥有尺寸**：产品已经定义工作区宽高，内容必须在该画布内排版和滚动时，使用固定 AppKit sheet。

> `.frame(width:height:)` 只约束 SwiftUI 内容，不会关闭 SwiftUI presentation bridge 的 fitting-size 协商。复杂页面即使把 `minWidth/maxWidth/minHeight/maxHeight` 设为同值，仍可能在展示前多次执行 `sizeThatFits`。

## 2. 使用自动 SwiftUI Sheet

以下条件应同时成立：

- 任务是确认、轻量设置、新建/编辑表单等单一操作。
- 主要结构为单列，内容规模可预测，最多只有一个 `ScrollView` 或 `List`。
- 不包含双栏工作台、多个全高弹性容器或相互依赖的 `.infinity` 布局。
- 首帧不需要展开大型集合，也不会连续写入多个影响结构的 `@Observable` 状态。
- 实际打开和关闭没有出现可感知卡顿、彩虹光标或大量重复 `sizeThatFits`。

推荐写法：

```swift
.sheet(isPresented: $showEditor) {
    EditorSheet(...)
        .appLocaleEnvironment()
}
```

适用示例：

- 删除确认、应用确认。
- `GitHubStarListEditorSheet` 这类固定宽度的单列表单。
- 从固定 AppKit 工作区打开的轻量子表单；父窗口的几何尺寸不能再由该子表单反向驱动。

## 3. 使用固定 AppKit Sheet

出现以下任一条件时，应优先使用固定 AppKit sheet：

- 产品已经规定明确工作区尺寸，例如 `960 × 640`，窗口不应根据内容变化。
- 页面包含两个或更多主要面板、多个滚动区、`List`、`GeometryReader`，或大量 `maxWidth/maxHeight: .infinity`。
- 页面承载可恢复的长生命周期 Session、大列表、审核工作台或持续更新的任务状态。
- 本地化文本、字号倍率或状态切换会明显改变内容的 ideal size。
- Instruments / `sample` 已观察到 presentation bridge、`sizeThatFits`、`StackLayout` 或 `ScrollView` 的重复主线程计算。
- 打开或关闭时已经出现秒级延迟、彩虹光标；此时不得继续靠 loading 占位掩盖尺寸协商。

固定实现必须满足：

1. 在创建 SwiftUI hosting tree **之前**准备首帧所需的轻量内存快照。
2. 由 `NSWindow` 明确设置 `contentRect`、`contentMinSize` 和 `contentMaxSize`。
3. 设置 `NSHostingController.sizingOptions = []`，禁止 SwiftUI intrinsic/preferred size 反向改变窗口。
4. SwiftUI 仍是业务状态真源；AppKit controller 只负责窗口创建、展示和关闭回调。
5. Hosting root 必须注入所需本地化、字号和依赖环境；优先复用 `.appHostEnvironment(...)`。
6. 只给真正需要滚动的区域添加 `ScrollView` / `List`，其余面板使用稳定宽高。
7. 关闭时直接结束 AppKit sheet 并释放 hosting tree，不重新进入 SwiftUI `.dismiss` presentation bridge。

参考骨架：

```swift
let hostingController = NSHostingController(rootView: content)
hostingController.sizingOptions = []

let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: contentSize),
    styleMask: [.titled, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
window.contentViewController = hostingController
window.contentMinSize = contentSize
window.contentMaxSize = contentSize
parentWindow.beginSheet(window)
```

参考实现：`Starcat/Features/Home/GitHubStarListAIGroupingWindowController.swift`。

## 4. 禁止做法

- ❌ 把 SwiftUI 根视图的 `min/max` 设为同值，就宣称窗口已经固定。
- ❌ 用“正在准备”或空白占位延迟复杂页面出现，把偶然减少布局量当成性能修复。
- ❌ 为只展示几个统计数字的静态首屏重新查询数据库或展开完整模型数组。
- ❌ 在 `.task` 中连续写入多个首帧结构状态，让窗口出现后再经历第二轮完整布局。
- ❌ 在固定工作区里给所有面板都套 `ScrollView` 或 `.infinity`。
- ❌ 为轻量子表单重复注入它不读取的完整依赖树。

## 5. 选型示例

| 场景 | 选择 | 原因 |
|---|---|---|
| AI 仓库分组审核工作区 | 固定 AppKit sheet | 双栏、固定 `960 × 640`、Session 与审核列表 |
| AI 仓库分组内“新增分组” | 自动 SwiftUI sheet | 单列、固定宽度、内容规模小 |
| 删除 / 应用确认 | 自动 SwiftUI sheet / dialog | 内容短且尺寸稳定 |
| 多面板数据审核与长期任务窗口 | 固定 AppKit sheet | 产品尺寸优先，内容在窗口内滚动 |

## 6. 提交前自检

- [ ] 已明确尺寸由内容还是产品工作区拥有。
- [ ] 自动 sheet 满足单列、轻量、尺寸稳定和最多一个滚动区。
- [ ] 固定 sheet 使用 `NSWindow` 明确尺寸，并设置 `NSHostingController.sizingOptions = []`。
- [ ] 首帧状态在创建 hosting tree 前一次性准备，没有用 loading 占位遮挡布局问题。
- [ ] 固定工作区只保留必要滚动区，没有无边界 `.infinity` 互相协商。
- [ ] 本地化、字号倍率、明暗主题和关闭路径均已验证。
- [ ] 打开、关闭及嵌套轻量表单没有可感知卡顿或彩虹光标。
