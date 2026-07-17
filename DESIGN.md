---
version: alpha
name: Starcat
description: AI-readable design contract for Starcat's macOS UI, including the main three-column app, Agent workspace, and Knowledge RAG workspace.
colors:
  primary: "#007AFF"
  accent: "#007AFF"
  accent-strong: "#0057D9"
  on-accent: "#FFFFFF"
  selected-light: "#EAF3FF"
  selected-dark: "#102A43"
  success: "#34C759"
  warning: "#FF9500"
  danger: "#FF3B30"
  text-primary-light: "#1D1D1F"
  text-secondary-light: "#6E6E73"
  surface-light: "#F5F5F7"
  panel-light: "#FFFFFF"
  separator-light: "#D2D2D7"
  text-primary-dark: "#F5F5F7"
  text-secondary-dark: "#A1A1AA"
  surface-dark: "#1C1C1E"
  panel-dark: "#2C2C2E"
  separator-dark: "#3A3A3C"
typography:
  workspace-title:
    fontFamily: SF Pro Display
    fontSize: 20px
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: 0em
  panel-title:
    fontFamily: SF Pro Text
    fontSize: 17px
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: 0em
  row-title:
    fontFamily: SF Pro Text
    fontSize: 15px
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: 0em
  body-emphasis:
    fontFamily: SF Pro Text
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: 0em
  body:
    fontFamily: SF Pro Text
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: 0em
  input:
    fontFamily: SF Pro Text
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: 0em
  caption:
    fontFamily: SF Pro Text
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.3
    letterSpacing: 0em
  caption-strong:
    fontFamily: SF Pro Text
    fontSize: 12px
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: 0em
  caption-small:
    fontFamily: SF Pro Text
    fontSize: 11px
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: 0em
  code:
    fontFamily: SF Mono
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: 0em
  icon-small:
    fontFamily: SF Symbols
    fontSize: 13px
    fontWeight: 500
    lineHeight: 1
    letterSpacing: 0em
  icon-medium:
    fontFamily: SF Symbols
    fontSize: 15px
    fontWeight: 500
    lineHeight: 1
    letterSpacing: 0em
  icon-large:
    fontFamily: SF Symbols
    fontSize: 18px
    fontWeight: 500
    lineHeight: 1
    letterSpacing: 0em
spacing:
  micro: 4px
  xs: 6px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 24px
  page: 28px
rounded:
  sm: 5px
  md: 8px
  lg: 12px
  panel: 16px
  full: 9999px
components:
  rail:
    backgroundColor: "{colors.panel-light}"
    textColor: "{colors.text-primary-light}"
    width: 312px
  rail-dark:
    backgroundColor: "{colors.panel-dark}"
    textColor: "{colors.text-primary-dark}"
    width: 312px
  inspector:
    backgroundColor: "{colors.surface-light}"
    textColor: "{colors.text-primary-light}"
    width: 420px
  inspector-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.text-primary-dark}"
    width: 420px
  icon-button:
    textColor: "{colors.text-secondary-light}"
    rounded: "{rounded.md}"
    size: 28px
  icon-button-dark:
    textColor: "{colors.text-secondary-dark}"
    rounded: "{rounded.md}"
    size: 28px
  primary-action:
    backgroundColor: "{colors.accent-strong}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.md}"
    padding: 10px
  selected-row:
    backgroundColor: "{colors.selected-light}"
    textColor: "{colors.text-primary-light}"
    rounded: "{rounded.md}"
  selected-row-dark:
    backgroundColor: "{colors.selected-dark}"
    textColor: "{colors.text-primary-dark}"
    rounded: "{rounded.md}"
  separator:
    backgroundColor: "{colors.separator-light}"
    height: 1px
  separator-dark:
    backgroundColor: "{colors.separator-dark}"
    height: 1px
  status-success:
    backgroundColor: "{colors.success}"
    textColor: "{colors.text-primary-light}"
    rounded: "{rounded.full}"
  status-warning:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.text-primary-light}"
    rounded: "{rounded.full}"
  status-danger:
    backgroundColor: "{colors.danger}"
    textColor: "{colors.text-primary-light}"
    rounded: "{rounded.full}"
---

# DESIGN.md

Starcat 的 UI 设计契约。任何新增或修改 UI 的 AI Agent 都必须先读本文件，再读相关代码和 `docs/5-规范/` 中的强制规范。

本文件不是第二套视觉真相。强制规则仍以 `docs/5-规范/*.md` 为准；本文件负责把 Starcat 的视觉意图、布局密度和组件边界压缩成 AI 容易执行的单页上下文。

## Overview

Starcat 是面向重度 GitHub 用户的 Apple 原生生产力工具。界面应该像 Finder、Xcode Organizer、Mail 这类 macOS 工具一样可靠、安静、可扫描：信息密度高，但层级清楚；控件克制，但状态明确；优先帮助用户整理、理解、找回、评估仓库，而不是展示品牌视觉。

Starcat 的核心界面包含三类一等场景：

- 主窗口三栏：Sidebar / Repo List / Detail，是长期停留和高频筛选的工作区。
- Agent 工作台：Agent rail / Run Surface / Artifact Inspector，是覆盖式任务执行区，用于步骤、工具、产物和确认流。
- 知识库 RAG 工作台：Conversation rail / Answer Surface / Citation Inspector，是只读问答与证据核验区。

三类场景都必须保持同一种 macOS 工具气质：系统色、系统材质、8pt 附近的紧凑间距、8px 左右圆角、清晰分隔线、明确的选中态、少装饰、少渐变、少自定义视觉噪音。

## Colors

Starcat 使用系统语义色优先。SwiftUI 代码中，文本和图标默认使用 `.primary` 或 `.secondary`，不要手写固定灰色，也不要随手使用 `.tertiary`。`.tertiary` 只允许用于故意弱化的装饰性占位，并且代码注释必须写明产品意图。

Accent color 只用于可操作状态和当前选择，不用于大面积铺底。成功、警告、危险色只表达状态，不承担装饰用途。

浅色模式应该接近 `NSColor.windowBackgroundColor` / `controlBackgroundColor` 的层级；深色模式应该依赖系统背景和材质，不要强行做纯黑科技风。选中态通常是 `Color.accentColor.opacity(0.12)` 加轻量描边，而不是高饱和填充。

## Typography

字体跟随 Apple 系统字体。SwiftUI 中优先使用 `.title3`、`.headline`、`.subheadline`、`.callout`、`.caption`、`.caption2` 等动态层级，并通过 `starcatInterfaceScale` 接入已验证页面的字号倍率。

Apple 的系统字体会按字号自动处理 optical size：小字号使用更适合阅读的 SF Pro Text，20pt 及以上使用更适合标题的 SF Pro Display。Starcat 代码应优先使用 SwiftUI text style；只有在已接入 `starcatInterfaceScale` 的高密度页面，才使用显式基准字号乘倍率。

主窗口、Agent 工作台、知识库 RAG 工作台必须共享同一个 `InterfaceScale.multiplier`。不要为某个工作台额外放大或缩小一档；如果页面需要更强的可读层级，应选择更合适的 Typography token，而不是叠加第二套倍率。

Starcat 标准档字号规则：

| 场景 | SwiftUI 优先写法 | Token | 基准字号 |
|---|---|---|---|
| 工作台 / 详情主标题 | `.title3.weight(.semibold)` | `workspace-title` | 20pt |
| 二级面板标题 / inspector 标题 | `.headline.weight(.semibold)` | `panel-title` | 17pt |
| 列表主标题 / repo name / agent name | `.subheadline.weight(.semibold)` | `row-title` | 15pt |
| 重要正文 / 摘要小标题 | `.callout.weight(.medium)` 或缩放后 14pt | `body-emphasis` | 14pt |
| 正文 / 问答内容 / 普通说明 | `.body` 或缩放后 13pt | `body` | 13pt |
| 输入框 / composer | `.callout` | `input` | 16pt |
| 辅助说明 / subtitle / metadata | `.caption` | `caption` | 12pt |
| 轻量 section label / chip 文本 | `.caption.weight(.semibold)` | `caption-strong` | 12pt |
| 时间 / 小 badge / 极弱辅助 | `.caption2` | `caption-small` | 11pt |
| 代码 / 路径 / chunk / model id | `.caption.monospaced()` 或 `.system(..., design: .monospaced)` | `code` | 12pt |
| 小图标 / 元信息图标 | 跟随相邻 caption | `icon-small` | 13pt |
| 行内操作图标 | 跟随 row title / body | `icon-medium` | 15pt |
| 工作台入口 / rail header 图标 | 跟随标题 | `icon-large` | 18pt |

标题只用于当前区域的任务或对象名，不做网页式大标题。列表、rail、inspector 中的标题应更小、更紧，保证密度和可扫描性。代码、路径、模型名、chunk id 等技术元信息使用等宽字体或现有项目组件，不要让它们抢占主阅读层级。

不要在 Starcat 的工具界面里使用 `.largeTitle` 或 28pt 以上标题，除非是 onboarding / 空状态首屏这类低密度场景。主窗口、Agent 工作台和 RAG 工作台的最高层级通常止于 `.title3` / 20pt。

所有新增文案必须走项目 i18n 规范。不要为了原型方便在可发布路径硬编码长中文说明。

## Layout

Starcat 的布局是工具工作台，不是 landing page。

主窗口三栏遵循稳定职责：

- Sidebar：导航、账号概览、Tags、Languages、Smart Collections、Explore/Weekly 等入口。
- Repo List：搜索、筛选、排序、仓库行、批量操作。
- Detail：README、元数据、笔记、状态、AI 摘要、Release、Health 等当前仓库上下文。

Agent 工作台遵循覆盖式 run layout：

- Agent rail：约 312pt，列出 Agent 分类、当前选择和历史任务。
- Run Surface：主任务流，展示上下文、步骤时间线、工具调用、确认请求和输入 composer。
- Artifact Inspector：结构化结果、证据、行动、日志等产物，不能和步骤流混在一起。

知识库 RAG 工作台遵循问答证据 layout：

- Conversation rail：默认 318pt，可在 250-380pt 内拖拽并跨窗口重开恢复，展示最近问答、知识库状态、范围、索引就绪度和新会话入口。
- Answer Surface：主问答阅读区，至少保留 480pt 可用宽度，最大内容宽度受控，问题、答案、追问保持清晰节奏。
- Citation Inspector：默认 420pt，可在 320-520pt 内拖拽并跨窗口重开恢复，展示引用仓库、证据片段、README/笔记/摘要来源和可信度，不展示普通用户无法理解的内部调试字段。

所有固定结构都要给稳定宽度、`minWidth` / `idealWidth` 或明确 frame，避免 hover、标签、计数、加载态导致布局跳动。

## Elevation & Depth

Starcat 通过系统背景、`Divider`、轻量材质和选中态表达层级。不要用大阴影、发光、渐变光斑、玻璃球、bokeh、营销页背景或深色科技感装饰。

`.thinMaterial` 只用于局部按钮、状态块、轻量浮层和已存在的玻璃态交互，不要把每个 section 都做成浮动卡片。主页面 section 应该像 macOS 原生应用一样贴合窗口和分栏，不要卡片套卡片。

## Shapes

默认圆角以 8px 为主。列表行、状态块、按钮、chip 可以使用 5-8px；较大面板可使用 12-16px；胶囊只用于真实 chip、pill、搜索范围或系统语义明确的标签。

不要把所有东西都做成大圆角卡片。Starcat 的形状语言应该是“略带柔和的工具界面”，不是移动端消费应用。

## Components

优先复用项目已有组件和模式：

- Sheet 关闭：使用 `SheetCloseButton`，`xmark.circle.fill`，hierarchical，`.secondary`。
- icon-only 刷新：使用 `SyncIconButton` 或 `StarsSyncButton`，`arrow.triangle.2.circlepath`，静止 `.secondary`，刷新中 `.accentColor` 并旋转。
- `.buttonStyle(.plain)`：必须紧跟 `.focusEffectDisabled()`。
- 设置页独立操作按钮：必须右对齐。
- 设置页完整层级、图标与按钮规范：见 [`docs/5-规范/UI-设置页规范.md`](docs/5-规范/UI-设置页规范.md)。
- 数值输入：使用 `TextField` + 数字过滤 + 范围钳制；范围大时用 `Slider`；禁止 `Stepper`。

列表行应该承担主要扫描任务：左侧对象/图标，中间标题与摘要，右侧轻量状态或时间。标签数量要收敛，通常显示前 2-3 个，其余用更多态或二级视图承载。

状态 pill 用于状态，不用于装饰。Pro、Read-only、Streaming、Knowledge、Provider、Scope 等可以是 pill；普通说明文字不要强行 pill 化。

按钮要有真实命令语义。图标按钮必须有可理解的 SF Symbol 和 tooltip / accessibility label。不要新造手写 SVG 图标，除非已有资产体系没有合适符号。

## Component Patterns

Starcat 的组件应从少量稳定模式组合出来。新增 UI 时先寻找相近模式，不要按页面临时发明新样式。

### Sidebar / Rail Row

用于主窗口 Sidebar、Agent rail、RAG conversation rail。结构为左侧 13-17pt SF Symbol 或头像，中间主标题和一行可选 subtitle，右侧计数、时间或轻量状态。选中态使用 accent 的低透明背景和可选 1px 描边；hover 只做轻量背景变化，不缩放整行。

行高保持紧凑：单行导航约 30-34pt，双行对象约 48-58pt。不要把 rail row 做成大卡片，也不要给每行加阴影。

### Repo / Result Row

用于仓库列表、搜索结果、推荐结果。首行展示 repo full name 或短标题，右侧放 star、更新时间、心形状态等可比较信息；第二行展示描述；第三行才放 topics / language / health / provider 等轻量 metadata。标签默认最多展示 2-3 个，更多信息进入详情或 inspector。

选中态必须和 Sidebar / Rail Row 同源：低透明 accent 背景、轻量描边、`.primary` 主文字、`.secondary` 辅助文字。不要使用高饱和渐变或彩色边框表达普通选中。

### Inspector Section

用于详情右栏、Agent artifact inspector、RAG citation inspector。section 标题用 `panel-title` 或 `caption-strong`，内容用短段落、键值行、证据片段和 action row。Inspector 是核验信息的位置，不是营销卡片区。

Inspector section 可以使用 8px 圆角和 `.thinMaterial`，但不要卡片套卡片。多个 section 之间用 12-16pt 间距或 `Divider`，不要靠阴影制造层级。

### Header Chip / Status Pill

只用于真实状态：Read-only、Running、Streaming、Knowledge、Provider、Scope、Pro、Failed、Ready。chip 文本使用 `caption` / `caption-strong`，高度约 22-26pt，圆角使用胶囊或 6-8px。

不要把普通说明文字、营销词、静态标签都做成 pill。状态 pill 的颜色必须服务于状态语义，不服务于装饰。

### Composer / Input

Agent 和 RAG 的 composer 是命令入口，不是聊天产品装饰区。输入框使用 `input` token，保留清晰边界和足够点击区；发送、停止、附加上下文等按钮应使用明确 SF Symbol 和 tooltip。

多行输入要保持稳定最小高度，文本增长不应挤压 header、rail 或 inspector。长 prompt、URL、repo name 必须截断或换行，不能撑爆按钮和 pill。

### Empty / Loading / Error

空状态应该短、小、操作导向：一行标题、一行说明、一个主操作或返回路径即可。不要使用大插画、hero 标题或营销文案。

加载态优先使用行内 progress、skeleton、状态 pill 或已有同步按钮状态。错误态要提供恢复动作和可读错误摘要；危险色只标记失败或破坏性动作，不做大面积背景。

## State Rules

统一状态比单个页面好看更重要。新增状态时先映射到以下规则：

| 状态 | 视觉规则 |
|---|---|
| selected | accent 低透明背景 + 可选 1px accent 描边，主文字 `.primary` |
| hover | 低透明系统分隔色或 accent 轻微变化，不改变布局尺寸 |
| disabled | `.secondary` 降低透明度，保留可读，不使用 `.tertiary` 普通文字 |
| loading | 行内 progress / rotating `SyncIconButton` / Streaming pill，避免全屏 spinner |
| error | 小面积 danger 标识 + 恢复动作，错误详情进入 disclosure / log |
| read-only | lock 图标 + Read-only pill，禁用写入按钮但保留浏览能力 |
| Pro-gated | lock / sparkles 小标识 + 清晰 CTA，不把整个功能做成广告卡片 |
| streaming | 绿色或 accent 状态 pill + 停止按钮，输出区域保持稳定宽度 |
| waiting confirmation | 明确确认区，主操作和取消操作并列，不自动写入数据 |

Agent 工作台的 running / stopped / failed / waiting confirmation 必须在 header、timeline、composer 三处表达一致。RAG 工作台的 citation selected / answer streaming / retrieval failed 必须在 answer surface 与 citation inspector 中保持同一状态口径。

## Text & Localization

Starcat 的 UI 必须承受中文、英文、repo full name、模型名、URL、错误消息和 provider 名称同时出现。新增组件时默认考虑长文本：

- repo full name、URL、model id、provider name：优先单行截断，必要时 tooltip 展示完整值。
- 普通说明：最多 2 行；超过 2 行应进入详情、popover 或 inspector。
- Button 文案：短动词或动宾短语；按钮过窄时优先使用图标 + tooltip，不缩小字号硬塞。
- Badge / pill：只放短状态，不放长句。
- Error message：用户可读摘要在前，技术细节进入 disclosure 或日志。

不要通过负 letter spacing、视口宽度缩放字体或极小字号解决溢出问题。

## Settings, Sheets, and Popovers

Settings 是配置表单，不是功能展示页。section 标题简短，说明文字放在控件下方或 footer；独立操作按钮右对齐；危险操作进入危险区并使用二次确认。设置页具体的字体层级、图标尺寸、按钮分类与验收清单以 [`docs/5-规范/UI-设置页规范.md`](docs/5-规范/UI-设置页规范.md) 为准。

Sheet / popover 应只承载一个明确任务。Sheet header 右上角关闭使用 `SheetCloseButton`；轻量上下文使用 popover；阻塞式任务或复杂表单使用 sheet。不要在 sheet 内再放一组浮动大卡片。

API Key、provider、模型、缓存、导出等设置 UI 需要统一：输入控件宽度稳定，测试结果提示收敛为单条，成功/失败状态不改变布局高度。

## Do's and Don'ts

Do:

- 先查现有页面和共享组件，再新增 UI。
- 保持主窗口、Agent 工作台、RAG 工作台的分栏结构、背景层级和选中态一致。
- 使用系统语义色和系统材质，优先适配明暗主题。
- 让用户能快速扫描：标题短、辅助文字弱、计数靠右、状态可比较。
- 为调试期入口使用 Debug 菜单或 debug-only 开关，不要把未完成工作台暴露到普通 Settings。
- 对 Agent / RAG 输出保持证据导向：步骤、工具、引用、产物要分区清楚。

Don't:

- 不要把 Starcat 做成网页 SaaS dashboard、marketing hero、卡片瀑布流或品牌 landing page。
- 不要新增大面积渐变、发光边框、彩色阴影、装饰性插画背景、圆形光斑。
- 不要在主窗口、Agent 工作台、RAG 工作台里引入互相冲突的按钮、chip、卡片和 header 风格。
- 不要使用 `.tertiary` 作为普通文字或图标颜色。
- 不要使用 `arrow.clockwise`、裸 `ProgressView` 或 `.symbolEffect(.rotate, value:)` 自制刷新按钮。
- 不要使用 `Stepper`。
- 不要为单个新页面临时发明新的 spacing scale、圆角体系或列表行结构。
- 不要把仅供开发验证的字段暴露给普通用户，例如原始 chunk id、内部 scorer、调试 JSON、未解释的 tool payload。

## UI Change Checklist

提交任何 UI 变更前，逐项检查：

- 是否先读过本文件和相关现有 Swift 页面？
- 是否复用了已有共享组件或相近页面模式？
- 是否使用 `.primary` / `.secondary`，没有把 `.tertiary` 用作普通文字或图标？
- 使用 `.buttonStyle(.plain)` 的按钮是否紧跟 `.focusEffectDisabled()`？
- Sheet 关闭是否使用 `SheetCloseButton`？
- icon-only 刷新是否使用 `SyncIconButton` / `StarsSyncButton`？
- 是否避免了 `Stepper`、随机渐变、大圆角卡片、卡片套卡片和网页式 hero？
- 明暗主题下文字、图标、状态 pill 是否可读？
- 长中文、长英文、repo full name、URL、模型名是否不会撑爆布局？
- loading / error / empty / disabled / selected / hover 状态是否都有稳定表现？
- Agent / RAG 输出是否把步骤、工具、证据、产物、日志分清楚？
- 未完成或调试期功能是否藏在 Debug，而不是普通 Settings 或主入口？
