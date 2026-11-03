# UI 规范：设置页

> **强制，2026-07-15 起生效**
>
> 设置页的完整样式与交互规范。全局视觉语言以 [`DESIGN.md`](../../DESIGN.md) 为准；本文只定义 macOS `Settings` / 偏好设置表单的专属约束。与已有专项规范冲突时，Sheet 关闭、刷新、复制、Focus Ring、颜色、数值输入、i18n 等专项规范优先。

---

## 1. 目标与适用范围

设置页是帮助用户完成配置的原生表单，不是功能展示页。它必须让用户快速识别：**我正在配置哪一组能力、每个控件改变什么、下一步该点哪个动作、是否已成功或有风险**。

适用范围：`SettingsView` 内所有 Tab，以及由设置页打开的配置 sheet / popover。普通主窗口、工作台、详情页不直接套用本文的字号和按钮尺寸。

必须使用 `Form` + `.formStyle(.grouped)`。禁止为了视觉效果把每个 `Section` 再包成自定义大卡片、hero 区或营销式渐变背景。

## 2. 信息层级与字体

所有文本优先使用 SwiftUI 动态文字样式，禁止为普通设置项继续新增硬编码 `Font.system(size:)`。基准字号用于理解视觉层级，不是鼓励写死字号。

| 层级 | SwiftUI 写法 | 基准 | 颜色与使用边界 |
|---|---|---:|---|
| 分组名称 | `.body.weight(.semibold)` | 13pt | `.primary`；只用于 `Section` header，与行 Label 同字号，仅以字重表达分组边界 |
| 行 Label | `.body` | 13pt | `.primary`；用于 Toggle、Picker、TextField、`LabeledContent` 的主标签 |
| 行内小标题 | `.callout.weight(.medium)` | 14pt | `.primary`；只用于复杂行的内部标题，不能替代分组名称 |
| 说明 / footer | `.caption` | 12pt | `.secondary`；说明控件作用、限制、下一步或当前状态 |
| 技术值 | `.caption.monospaced()` | 12pt | `.secondary`；用于路径、URL、端口、API Key、模型 ID 等机器可读值 |
| 极弱元信息 | `.caption2` | 11pt | `.secondary`；仅用于时间、短计数和非关键附注 |

规则：

- 一个 `Section` 只能有一个分组名称。已有 `SettingsSectionHeader` 时，Section 内容不得再放同义 `.headline` / `.title3` 标题。
- 控件需要解释时，说明紧随控件下方；跨多行或涵盖整组配置的说明使用 `Section` footer。
- Label 与其说明之间使用 `spacing: 2`；同一行控件和行内操作使用 `spacing: 8`；复杂信息块之间使用 `spacing: 12`。无特殊原因时优先让 `Form` 管理 Section 内外间距。
- 普通文字与图标只用 `.primary` / `.secondary`。成功、警告、错误可以使用语义色，但语义色不能承担装饰作用。

## 3. 分组名称与图标

所有带图标的 `Section` header 必须使用 `SettingsSectionHeader`，不得在各 Tab 自行拼装标题样式。

`SettingsSectionHeader` 的标准为：

| 项目 | 标准 |
|---|---|
| 标题 | `.body.weight(.semibold)`，`.primary`；与行 Label 同为 13pt，仅字重不同 |
| SF Symbol | 13pt medium，`.secondary` |
| 图标布局框 | 20 × 20pt |
| 标题与图标间距 | 6pt |
| 图标背景 | 默认**无背景** |

图标背景只用于表达功能身份或状态，例如 Pro 锁定态、明确的成功/警告/危险状态；此时统一为 28 × 28pt 容器、18pt glyph，并使用轻量系统语义色。不能为普通 Section 图标随机添加色块。

## 4. 设置行

### 4.1 标准配置行

优先使用系统 `Toggle`、`Picker`、`TextField`、`LabeledContent`，Label 保持 `.body`。当 Label 需要说明时使用以下结构：

```swift
Toggle(isOn: $setting) {
    VStack(alignment: .leading, spacing: 2) {
        Text("settings.example.title")
        Text("settings.example.description")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

数值输入遵循 [`UI-禁止Stepper-规范.md`](UI-禁止Stepper-规范.md)：使用 `TextField` + 过滤与范围钳制，禁止 `Stepper`。

### 4.2 值与行内操作

路径、Key、端口等技术值使用等宽 caption，并保持单行截断；完整值通过 `textSelection`、tooltip 或“复制”提供，不靠缩小字体解决溢出。

与当前值直接绑定的复制、显示/隐藏、在 Finder 打开、重置操作放在值的右侧，组成单一行内操作组；不要把这些动作挪成独立 Section。复制、重置分别必须复用 `CopyFeedbackButton`、`ResetIconButton`。

连接字段复用 `SettingsConnectionFieldRow`，同页标签列、输入列与尾部操作槽对齐。标签允许换行，输入框可收缩；API Key 复用 `SettingsAPIKeyField`，显示/隐藏通过 `SettingsActionIconButton`，切换后保留草稿并恢复焦点。已有配置弹框可保留自身列宽，但必须复用相同的操作按钮。

主设置页滑条复用 `SettingsSliderRow`：左侧标题、右侧轨道和数值同排居中；同宽容器中轨道长度与读数列宽一致，窄窗口统一收缩轨道，长标题换行。模型参数 popover 等紧凑浮层可保留专用布局。

## 5. 按钮规范

### 5.1 内容形式的选择

以下是 Starcat 设置页的统一约定，依据 macOS 原生控件语义制定，不应表述为 Apple 要求所有设置按钮采用相同形式的硬性规定。

| 形式 | 选择条件 | 设置页示例 |
|---|---|---|
| 纯文字（默认） | 需要读到动作名称才能明确含义的常规操作 | Choose、测试连接、测试并保存、测试并应用、管理服务商、编辑提示词、安装、删除模型、重建、导出、校验授权 |
| 纯图标 | 紧邻明确对象、含义常见且空间紧凑的快捷操作；必须有 tooltip 与无障碍名称 | 显示/隐藏密码、复制、在 Finder 显示、恢复默认、刷新、帮助；密集列表中的下载、暂停、重试和删除 |
| 图标 + 文字（例外） | 图标能提供文字没有表达的识别信息，且该操作确为任务区的主入口；需要在代码中说明理由 | 同一任务区最多一个，不因按钮是主操作就自动添加图标 |

- 不给普通操作附加装饰性 `network`、`play`、`trash`、`gearshape` 等图标。主次关系由系统按钮样式表达，危险性由 `role: .destructive` 和后果说明表达。
- 相同动作跨页采用相同形式；不能一处“测试连接”带网络图标，另一处只显示文字。
- 成功、失败和加载属于状态，放在按钮外的反馈区。不得将按钮图标换成成功勾，或用 spinner 替换按钮文字；测试期间保持标题与按钮宽度稳定。
- 侧边栏、服务商/模型选择项、设备身份图标与分组标题不属于操作按钮装饰，保留其识别用途。导航/折叠的 chevron 表达结构状态，也不按装饰图标删除。
- 不因长译文放不下就把安装、重建等语义不明确的操作改成图标；应先调整布局与文案。保留的图标入口必须按 5.3 提供完整语义。

### 5.2 带文本按钮

| 类型 | 样式 | 使用场景 |
|---|---|---|
| 主操作 | `.borderedProminent` + `.controlSize(.regular)` | 当前任务唯一的开始、保存、升级、确认动作 |
| 次操作 | `.bordered` + `.controlSize(.regular)` | 选择目录、测试连接、导出、打开 Finder 等可逆动作 |
| 轻操作 | 系统默认文本 Button | 与当前配置紧密绑定、且不应抢夺控件注意力的动作 |
| 危险操作 | `role: .destructive`，并二次确认 | 清除、删除、重置不可恢复数据 |

默认使用 `Button("key")` 或 `Text` 标签，不为隐藏装饰图标添加一套自定义按钮样式。获准使用图标 + 文字时，图标使用 15pt；文案使用短动词或动宾短语。一个独立任务区最多一个主操作，不能把同级动作全部做成 `.borderedProminent`。

不与某一行控件直接绑定的独立操作必须右对齐：

```swift
HStack {
    Spacer()
    Button("settings.example.export") { export() }
        .buttonStyle(.bordered)
        .controlSize(.regular)
}
```

当操作附带状态或提示时，提示在左、按钮在右，放在同一个 `HStack`，不得再单独增加一行右侧按钮。

同义动作复用同一文案与样式：选择文件/目录统一使用短文案 `Choose`；获取密钥统一 `Get API key`；管理服务商统一 `Manage providers`。英文使用 sentence case，保留 API、产品名等专有名称的大小写。省略号只用于还需输入或确认的动作，普通跨页导航不加省略号。测试、保存和应用含义不同，不能仅为统一字面而混用。

省略号表示执行前还需要用户提供信息或确认，不表示执行耗时。打开文件/目录选择器、导出位置选择器或重建确认窗口可以使用；直接执行测试、刷新、暂停、恢复任务以及普通跨页导航不使用。图标形式、颜色和省略号不能替代必要的确认流程。

### 5.3 icon-only 按钮

设置页的 icon-only 按钮统一为 **15pt glyph + 28 × 28pt 命中区**。默认 `.secondary`，hover 仅改变轻量背景或颜色，不缩放、不改变布局。

| 语义 | 必须组件 / 规则 |
|---|---|
| 刷新 / 同步 | `SyncIconButton`；刷新中使用 `.accentColor` 与旋转 |
| 复制 | `CopyFeedbackButton`；成功 1.5 秒显示绿色 `checkmark.circle.fill` |
| 重置 | `ResetIconButton`；成功反馈后自动恢复 |
| 删除 / 清空 | `DestructiveIconButton`；业务删除仍必须二次确认 |
| 取消 / 放弃草稿 | `CancelIconButton`；草稿未落盘，不二次确认 |
| 其他常见行尾操作 | `SettingsActionIconButton`；禁止新写裸 `Button { Image(...) }`；已有密集列表可保留专用组件，但必须补齐提示和无障碍名称 |

每个 icon-only 按钮必须有 tooltip 与 accessibility label。使用 `.buttonStyle(.plain)` 时，必须紧跟 `.focusEffectDisabled()`。

## 6. 状态、风险与反馈

- 成功、失败、测试中三种状态必须使用操作行左侧同一位置。长错误可换行，技术详情可另行折叠；不得把成功反馈单独挪到另一行。
- 测试按钮使用纯文字，加载时标题保持不变。`ProgressView` 与成功/失败图标放在按钮外的状态区，不在空闲按钮内保留装饰图标或空图标槽。
- 加载优先使用行内 `ProgressView` 或 `SyncIconButton`，禁止在设置页用全屏 spinner 覆盖表单。
- “测试连接”只验证；“测试并保存/应用”必须验证成功后才提交该次输入快照。失败不得覆盖原可用连接，凭据保存失败不得显示成功；自动检测不得隐式保存草稿。
- 地址、模型、Key 或连接类型变化时，立即清除过期反馈；异步返回须校验请求身份，过期请求不得保存配置、启用连接或覆盖新结果。异步提交期间禁用相关编辑和重复操作。
- 错误先给用户可理解的摘要；技术细节进入 disclosure、日志或诊断导出。
- 危险操作集中在 `Danger Zone`，分组标题或后果说明区可用危险图标；按钮使用明确文字和危险角色，执行前必须确认。
- 尊重“减少动态效果”：动画只增强反馈，不能是理解成功、失败或当前状态的唯一方式。

## 7. 可访问性、明暗主题与本地化

- 图标按钮必须提供 tooltip 与 accessibility label；图标本身不能是唯一语义来源。
- 普通文本/图标禁止 `.tertiary`，详见 [`UI-颜色规范.md`](UI-颜色规范.md)。
- 使用系统语义色、系统控件与 `.grouped` Form，保证明暗主题下的对比度；不额外铺设纯黑背景或高饱和渐变。
- 所有新增或修改文案遵循 [`国际化-规范.md`](国际化-规范.md)：覆盖全部支持语言（当前 17 种，以 `AppLocale` 排除 `system` 后与 `supports/starcat-localization/locales.json` 核对），key 使用 `{section}.{subsection}.{component}`。AI 初稿保留 `needs_review`，英语兜底不算译文完成。
- 由设置页打开的 sheet / popover 根视图必须注入 `.appLocaleEnvironment()`，不能依赖浮层自动继承主页面语言。

## 8. 新增或调整设置页的验收清单

- [ ] 使用 `Form` + `.formStyle(.grouped)`，没有卡片套卡片或 hero 化布局。
- [ ] 每个 Section 只有一个 `SettingsSectionHeader`；标题、Label、说明符合第 2 节层级。
- [ ] 新增图标符合第 3 节尺寸，普通分组图标没有背景色块。
- [ ] 文本按钮已按主/次/轻/危险动作分类；独立操作已右对齐。
- [ ] 常规操作默认纯文字；图标 + 文字仅用于有明确理由的主入口，图标入口有可识别的邻接对象。
- [ ] icon-only 操作复用既有组件或统一封装，具备 28 × 28pt 命中区、tooltip、accessibility label。
- [ ] 复制、刷新、重置、删除分别符合对应专项规范；危险动作具备二次确认。
- [ ] 普通文字/图标未使用 `.tertiary`；明暗主题、disabled、loading、error 状态均可读。
- [ ] `.buttonStyle(.plain)` 已禁用 focus ring；动画尊重减少动态效果。
- [ ] 测试状态与操作同行，加载进度位于按钮外，按钮文字和宽度稳定；失败、取消、编辑后旧请求均不能提交配置。
- [ ] 滑条与连接字段使用共享列宽；长标签允许换行，密码显示切换保留草稿和焦点。
- [ ] 新增或修改字符串满足全语言覆盖与命名规范，sheet / popover 已注入应用语言环境。

## 9. 例外

仅当系统控件、可访问性需求或既有专项规范要求不同表现时允许例外。例外必须在代码注释中说明原因和适用范围；不能因为某一页“看起来更特别”而自建第二套设置页样式。
