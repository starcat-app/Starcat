# Starcat UI 优化指导手册

> 创建：2026-06-01
> 目的：为 Starcat 后续 UI 专题改造提供统一方向。本文先定义设计原则、组件规范、动效策略和迭代路线，再进入具体 SwiftUI 实现。

---

## 1. 目标与边界

Starcat 的 UI 目标不是把 macOS 原生界面彻底重画一遍，而是在原生三栏结构上补足视觉层次、数据表达和状态反馈。

### 1.1 目标

- 保留 macOS 原生结构：`NavigationSplitView`、系统 toolbar、sidebar、popover、sheet 仍是骨架。
- 增加适度酷感：通过卡片层次、hover、selection、状态动效、语义色和微交互实现，不靠大面积装饰。
- 让数据更有表情：语言、标签、状态、Star/Fork/Watch、AI 推荐、同步状态都要有可识别的视觉编码。
- 兼容 Light / Dark：所有颜色、材质、边框、阴影都必须在两种主题下可读。
- 对 dong4j 友好：每次引入新的 SwiftUI / AppKit 概念，要在 `docs/Swift 学习索引.md` 补关键词和项目位置。

### 1.2 非目标

- 不引入一整套 Web 式 UI 框架。
- 不用重度自绘替代系统 sidebar / toolbar / sheet。
- 不用到处发光、超强渐变、复杂 3D 或持续循环动画来制造“酷炫”。
- 不让 README 阅读区被装饰元素干扰。README 是内容阅读面，优先保证可读性。

---

## 2. 当前界面诊断

基于 2026-06-01 截图，当前 UI 的优点是：三栏结构清晰、系统组件使用充分、信息密度适合桌面端。

主要短板：

| 区域 | 问题 | 优化方向 |
|---|---|---|
| Sidebar | 系统感强，但品牌记忆点弱 | 保留原生 source-list 密度，增强用户卡、分组标题和状态色 |
| Repo List | 列表项层次偏平，选中态与普通态主要靠系统蓝色 | 做 hover / selected 过渡，卡片态更有层次，避免依赖系统蓝色底 |
| Detail Header | 信息完整，但视觉重心不够明确 | 做 repo hero header，统计指标卡片化，标签/状态区更轻 |
| README | 阅读体验已可用 | 保持克制，只优化加载、空态、缓存信息和暗色适配 |
| Toolbar | 图标已经收敛，但状态表达弱 | 增加语义 badge、同步中/失败/完成反馈 |
| Empty / Error | 功能性足够，情绪表达不足 | 做生动状态页：图标、短文案、主操作、次操作 |

---

## 3. 设计原则

### 3.1 Native First

先使用 SwiftUI / AppKit 提供的标准能力，再考虑自定义。系统组件会自动适配窗口尺寸、键盘、VoiceOver、明暗主题和未来 macOS 外观。

优先级：

1. 系统结构：`NavigationSplitView`、`List`、`ToolbarItem`、`Menu`、`Popover`、`Sheet`。
2. 系统材质：`.regularMaterial`、`.thinMaterial`、semantic foreground style。
3. 轻量自定义组件：Repo row、metric badge、status chip、empty state。
4. AppKit interop：只在 SwiftUI 表达不稳定时使用。

### 3.2 Calm But Alive

Starcat 是工具型应用，应该长期使用不疲劳。动效要让状态变化更容易理解，而不是抢注意力。

- 列表选择、刷新、筛选、同步、保存这些动作适合微动效。
- AI 分析、空状态、首次引导可以更生动。
- README 阅读区、批量操作、危险操作保持冷静。

### 3.3 Color With Meaning

颜色必须承担信息意义，不能只是装饰。

- Blue：主操作、当前选中、可点击。
- Green：同步完成、已订阅、健康状态。
- Orange：需要注意、即将过期、限流倒计时。
- Red：危险操作、失败、取消 Star。
- Purple：AI 能力、智能推荐、语义搜索。
- Yellow：Star、收藏、重点提示。
- Language colors：编程语言识别，尽量与 GitHub 语言色一致。

### 3.4 Progressive Depth

层次从轻到重：

1. 系统背景：窗口 / sidebar / toolbar。
2. 内容表面：列表行、详情 header、README 容器。
3. 浮层：popover、toast、batch action bar。
4. 模态：sheet、confirmation dialog。

不要让每个区域都像浮起来的卡片。只有需要强调边界、选择、状态或操作的区域才使用卡片。

---

## 4. Design System 初稿

后续建议在代码中逐步沉淀到 `Shared/DesignSystem/`，但第一阶段可以先以局部组件实现。

### 4.1 色彩 Token

| Token | 用途 | SwiftUI 建议 |
|---|---|---|
| `Brand.primary` | 主操作、选中态 | `Color.accentColor` 或系统 blue |
| `Brand.ai` | AI 推荐、摘要、语义搜索 | purple，必须降低饱和度 |
| `Brand.star` | Star 数、收藏状态 | yellow |
| `Status.success` | 成功、已同步 | green |
| `Status.warning` | 限流、待处理 | orange |
| `Status.danger` | 删除、取消 Star | red |
| `Surface.card` | 卡片背景 | `Color(nsColor: .controlBackgroundColor)` + material |
| `Surface.selected` | 选中背景 | accent color opacity，暗色下更低透明度 |
| `Border.subtle` | 细边框 | `Color.primary.opacity(0.08...0.14)` |

规则：

- 禁止在 SwiftUI view 中散落 magic color。
- 不直接写纯白 / 纯黑背景。
- 暗色下减少阴影，更多依赖边框和 material。
- 亮色下可以用轻阴影，但半径和透明度要低。

### 4.2 字体 Token

| 场景 | 建议 |
|---|---|
| Sidebar row | `.callout` / `.subheadline`，保持紧凑 |
| Repo full name | `.headline` 或 `.subheadline.weight(.semibold)` |
| Description | `.callout` + `.secondary` |
| Metadata | `.caption` / `.caption2` |
| Detail title | `.title3.weight(.semibold)` |
| Empty state title | `.title3.weight(.semibold)` |

不要用过大的 hero 字体。Starcat 是桌面工具，主界面第一优先是扫描效率。

### 4.3 圆角与间距

| 类型 | 建议 |
|---|---|
| 小按钮 / chip | 6-8pt |
| Repo row card | 8-10pt |
| Detail metric card | 10-12pt |
| Toast / floating bar | 12-16pt |
| Sheet 内容区 | 跟随系统，不强行大圆角 |

间距优先使用 4 / 8 / 12 / 16 / 24。列表行内不要超过 12pt，否则密度会下降。

---

## 5. 组件规范

### 5.1 Repo Row

目标：让仓库列表既能高密度浏览，又能在卡片模式下有明确层次。

必须状态：

- normal：轻背景或无背景。
- hover：背景轻微增强，鼠标进入 120-180ms ease out。
- pressed：Repo List row 暂不做按压缩放，避免手势与 macOS List selection / Button 点击竞争。
- selected：稳定高亮，不依赖系统蓝色；使用左侧 2-3pt accent indicator + 轻背景 / 细边框。
- loading skeleton：继续保留现有骨架屏思路。
- reveal：切换分类或滚动到新 row 时，可对可视 row 做 120-220ms 的 opacity + 轻微 y-offset 入场；这属于视觉渐进，不等同于数据库分页。Manage repo list 与 Trending repo list 应复用同一套 `ListRowRevealModifier`。

建议展示：

- 第一行：头像 / owner/name / star。
- 第二行：description，最多两行。
- 第三行：language dot + language + status chip + tags preview。

约束：

- Sidebar 不做大卡片。Repo List 可以做卡片。
- 排序或过滤导致大规模重排时，不做 SwiftUI row move diff 动画，避免复现此前卡顿问题；如需逐行效果，只对当前可视 row 做短 reveal。
- 真正分页 / 无限滚动只在仓库量明显超过当前规模（例如 1 万以上）时再做，因为它会牵涉 Repository cursor、排序一致性、搜索和缓存策略。

### 5.2 Repo Detail Header

目标：详情页顶部要成为当前 repo 的视觉锚点。

结构建议：

1. Hero row：avatar、owner/name、license、topics、主操作。
2. Description：一段可读文案。
3. Metrics：Star / Fork / Watch / Created / Updated 做轻量指标卡。
4. User data：tags、status、notes 保持可编辑，但不要压过 README。

动效：

- 切换 repo 时 header 内容淡入 / 轻微位移。
- README 滚动隐藏信息面板的现有策略保留，继续使用 hysteresis，避免触控板回弹闪动。

### 5.3 Status Chip

状态不是纯文本，应该成为用户整理系统的一部分。

| 状态 | 视觉建议 |
|---|---|
| 未读 | neutral / envelope |
| 阅读中 | blue / book |
| 使用中 | green / hammer or terminal |
| 已废弃 | secondary / archive |

Chip 必须在明暗主题下都能读，不能只靠颜色区分，图标或文字也要明确。

### 5.4 Empty / Error / Login State

每个状态页统一包含：

1. SF Symbol 或轻量插图。
2. 一句明确标题。
3. 一句解释，避免技术错误直出给普通用户。
4. 一个主操作。
5. 可选次操作。

示例：

- 未登录查看详情：请登录后查看 README、标签和同步状态。
- 无搜索结果：没有找到匹配仓库，可清空筛选。
- Trending 加载失败：展示重试，而不是让中栏空白。
- 同步限流：展示剩余时间和取消按钮。

### 5.5 Toast / Feedback

Toast 用于“复制成功、保存成功、订阅成功”这类短反馈。

规则：

- 默认 2 秒消失。
- 出现在当前操作附近或窗口底部，不阻断用户。
- 成功 / 警告 / 失败使用不同图标和语义色。
- 不要把需要用户决策的内容放进 toast，那应该用 dialog 或 sheet。

---

## 6. 动效策略

### 6.1 动效分级

| 等级 | 场景 | 建议 |
|---|---|---|
| S | hover、button press、chip appear | 120-180ms |
| M | row selection、filter change、row reveal、panel collapse | 180-260ms spring / ease |
| L | empty state、AI analysis、onboarding | 400-800ms，可分阶段 |

### 6.2 SwiftUI 优先 API

优先学习和使用：

- `withAnimation`
- `.animation(_:value:)`
- `.transition`
- `matchedGeometryEffect`
- `PhaseAnimator`
- `KeyframeAnimator`
- `.symbolEffect`
- `TimelineView`（仅用于倒计时或明确时间驱动状态）

复杂动效不要先引库。只有当原生 API 做起来成本明显高，且动画属于产品关键体验时再引入第三方库。

### 6.3 避坑

- 大列表排序 / 过滤不做逐行 move 动画。Starcat 已经踩过 SwiftUI List 大规模 diff 卡顿。
- 不给所有 hover 都加 scale。工具型列表里 scale 太多会让界面不稳。
- 不做永久循环动画，除非表示正在进行中的任务。
- 尊重 Reduce Motion。后续实现时应读取 `@Environment(\.accessibilityReduceMotion)`。

---

## 7. Material / Liquid Glass 策略

Starcat 当前最低版本是 macOS 15。Liquid Glass 属于未来增强，不应成为基础 UI 的硬依赖。

### 7.1 macOS 15 基线

- 使用系统 adaptive colors。
- 使用 `.regularMaterial` / `.thinMaterial` 做浮层和状态条。
- 让 sidebar / toolbar 使用系统默认外观，不加厚重自定义背景。
- 自定义卡片只出现在内容区。

### 7.2 macOS 26 增强

在 `#available(macOS 26.0, *)` 中逐步加入：

- `glassEffect`：只用于浮层、状态条、少量强调组件。
- `GlassEffectContainer`：相邻玻璃元素必须放进同一个容器。
- toolbar grouping：优先用系统 toolbar 分组，不手写一条假 toolbar。

约束：

- 不为追求玻璃效果牺牲可读性。
- 不在 README 正文上方叠过重玻璃。
- 不把 Liquid Glass 当成“全应用透明化”。

---

## 8. 第三方库策略

引入依赖前先查 `docs/详细设计/04-技术选型.md`，并在 `docs/第三方资源使用记录.md` 记录用途、许可证和替代方案。

| 库 | 建议 | 用途 |
|---|---|---|
| Pow | 可评估 | SwiftUI transition / change effect，小型微交互 |
| Lottie | 谨慎引入 | onboarding、空状态、AI 分析中等高价值动画 |
| SwiftUIX | 默认不引 | 只有遇到 SwiftUI 明确缺口再考虑 |
| MarkdownUI | 不建议替换 README | 当前 WebView 路线满足 100% GFM 兼容 |

原则：

- 能用系统 API 解决，就不引库。
- 引库前必须明确“解决哪个具体问题”。
- 依赖不能只是为了“看起来高级”。

---

## 9. 分阶段路线

### Phase 0：规范沉淀（已启动）

- [x] 新增本文档，统一 Starcat UI 优化方向。
- [ ] 后续把本文档中的 token 逐步固化到 `Shared/DesignSystem/`。

### Phase 1：样板改造

范围建议：

1. Repo List row：hover、selected、语言/状态/tag chip、可视 row reveal。（2026-06-01 已完成首版样板：语言色 accent + metadata chips；普通单选态已移除系统蓝色底色；Manage / Trending 分类切换与滚动新 row 支持渐进式入场）
2. Repo Detail header：hero header + metric cards。
3. Empty / error / requires login state：统一状态页组件。

验收：

- Light / Dark 都截图检查。
- 列表滚动不卡顿。
- `buttonStyle(.plain)` 继续遵守 `.focusEffectDisabled()` 强制规则。
- 不改变数据流和同步逻辑。

### Phase 2：扩展到功能页

- Trending 页面：周期切换、语言筛选、订阅状态。
- Tags 管理：色板、图标选择、合并/删除反馈。
- Settings / About：统一表面、分组和空态。

### Phase 3：高级体验

- AI 分析中状态。
- Release timeline。
- macOS 26 Liquid Glass 可用时的增强层。
- 可选 onboarding。

---

## 10. 实现检查清单

每次 UI 改造前检查：

- [ ] 是否保留系统组件骨架？
- [ ] 是否支持 Light / Dark？
- [ ] 颜色是否有信息意义？
- [ ] 动效是否响应状态变化，而不是纯装饰？
- [ ] 是否尊重 Reduce Motion？
- [ ] `.buttonStyle(.plain)` 后是否添加 `.focusEffectDisabled()`？
- [ ] 是否避免大列表 move 动画？
- [ ] 是否需要补 `docs/Swift 学习索引.md`？
- [ ] 是否更新 `docs/工程进度/功能实现总览.md`？

---

## 11. SwiftUI 学习关键词

后续实现 Phase 1 时，优先补充这些关键词到 `docs/Swift 学习索引.md`：

| 关键词 | 建议项目位置 | 搜索词 |
|---|---|---|
| `matchedGeometryEffect` | Repo row / filter transition | "SwiftUI matchedGeometryEffect" |
| `PhaseAnimator` | Empty state / AI analyzing | "SwiftUI PhaseAnimator" |
| `KeyframeAnimator` | Success / completion feedback | "SwiftUI KeyframeAnimator" |
| `symbolEffect` | Toolbar status icon / sync icon | "SwiftUI symbolEffect SF Symbols" |
| `accessibilityReduceMotion` | Motion token 判断 | "SwiftUI accessibilityReduceMotion" |
| `Material` | Toast / floating bar / popover-like surface | "SwiftUI Material macOS" |
| `glassEffect` | macOS 26 增强 | "SwiftUI glassEffect GlassEffectContainer" |

---

## 12. 一句话方向

Starcat 应该像一个有 GitHub 气质的 macOS 原生知识库工具：结构稳定、信息清晰、状态生动、动效克制，酷感来自细节和数据表达，而不是重度皮肤化。
