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

## 5. 按钮规范

### 5.1 带文本按钮

| 类型 | 样式 | 使用场景 |
|---|---|---|
| 主操作 | `.borderedProminent` + `.controlSize(.regular)` | 当前任务唯一的开始、保存、升级、确认动作 |
| 次操作 | `.bordered` + `.controlSize(.regular)` | 选择目录、测试连接、导出、打开 Finder 等可逆动作 |
| 轻操作 | 系统默认文本 Button | 与当前配置紧密绑定、且不应抢夺控件注意力的动作 |
| 危险操作 | `role: .destructive`，并二次确认 | 清除、删除、重置不可恢复数据 |

带图标的文本按钮，图标使用 15pt；文案使用短动词或动宾短语。一个独立任务区最多一个主操作，不能把同级动作全部做成 `.borderedProminent`。

不与某一行控件直接绑定的独立操作必须右对齐：

```swift
HStack {
    Spacer()
    Button("settings.example.export") { export() }
        .buttonStyle(.bordered)
        .controlSize(.regular)
}
```

### 5.2 icon-only 按钮

设置页的 icon-only 按钮统一为 **15pt glyph + 28 × 28pt 命中区**。默认 `.secondary`，hover 仅改变轻量背景或颜色，不缩放、不改变布局。

| 语义 | 必须组件 / 规则 |
|---|---|
| 刷新 / 同步 | `SyncIconButton`；刷新中使用 `.accentColor` 与旋转 |
| 复制 | `CopyFeedbackButton`；成功 1.5 秒显示绿色 `checkmark.circle.fill` |
| 重置 | `ResetIconButton`；成功反馈后自动恢复 |
| 删除 / 清空 | `DestructiveIconButton`；业务删除仍必须二次确认 |
| 其他 | 后续统一封装为设置页专用 action button；禁止直接写裸 `Button { Image(...) }` |

每个 icon-only 按钮必须有 tooltip 与 accessibility label。使用 `.buttonStyle(.plain)` 时，必须紧跟 `.focusEffectDisabled()`。

## 6. 状态、风险与反馈

- 成功、失败、测试中三种状态必须使用同一位置，不得因状态变化造成整行跳动。
- 加载优先使用行内 `ProgressView` 或 `SyncIconButton`，禁止在设置页用全屏 spinner 覆盖表单。
- 错误先给用户可理解的摘要；技术细节进入 disclosure、日志或诊断导出。
- 危险操作集中在 `Danger Zone`，使用危险图标与明确后果文案；执行前必须确认。
- 尊重“减少动态效果”：动画只增强反馈，不能是理解成功、失败或当前状态的唯一方式。

## 7. 可访问性、明暗主题与本地化

- 图标按钮必须提供 tooltip 与 accessibility label；图标本身不能是唯一语义来源。
- 普通文本/图标禁止 `.tertiary`，详见 [`UI-颜色规范.md`](UI-颜色规范.md)。
- 使用系统语义色、系统控件与 `.grouped` Form，保证明暗主题下的对比度；不额外铺设纯黑背景或高饱和渐变。
- 所有新增文案遵循 [`国际化-规范.md`](国际化-规范.md)：同时维护 en 与 zh-Hans，key 使用 `{section}.{subsection}.{component}`。

## 8. 新增或调整设置页的验收清单

- [ ] 使用 `Form` + `.formStyle(.grouped)`，没有卡片套卡片或 hero 化布局。
- [ ] 每个 Section 只有一个 `SettingsSectionHeader`；标题、Label、说明符合第 2 节层级。
- [ ] 新增图标符合第 3 节尺寸，普通分组图标没有背景色块。
- [ ] 文本按钮已按主/次/轻/危险动作分类；独立操作已右对齐。
- [ ] icon-only 操作复用既有组件或统一封装，具备 28 × 28pt 命中区、tooltip、accessibility label。
- [ ] 复制、刷新、重置、删除分别符合对应专项规范；危险动作具备二次确认。
- [ ] 普通文字/图标未使用 `.tertiary`；明暗主题、disabled、loading、error 状态均可读。
- [ ] `.buttonStyle(.plain)` 已禁用 focus ring；动画尊重减少动态效果。
- [ ] 新增字符串满足双语与命名规范。

## 9. 例外

仅当系统控件、可访问性需求或既有专项规范要求不同表现时允许例外。例外必须在代码注释中说明原因和适用范围；不能因为某一页“看起来更特别”而自建第二套设置页样式。
