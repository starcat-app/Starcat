# AI 个人笔记生成审查报告 01：文档、需求与 Checklist 完整性

> 审查日期: 2026-07-22
> 审查基线: `dev@4835d0e`
> 范围: 正式方案、详细设计、专项 Checklist、验收步骤与已提交代码契约
> 结论: 发现 3 项功能契约缺口和 4 项文档漂移，本轮不通过，需先修复。

## 1. 审查方法

1. 逐条对照正式方案 §4 / §6 / §9 / §13 与 Checklist §1-§6。
2. 对照详细设计中的文件、类型、API、UI 结构和完成定义。
3. 核对实际代码中的折叠标题行、展开面板、七步状态机和保存链路。
4. 不把未执行的人工 UI 验收记为完成；仅确认验收契约文档已建立。

## 2. 发现

### P1-01：折叠标题行未展示七步的独立状态

- 需求证据：正式方案 §6.1 要求标题行显示七个紧凑状态点，用户在折叠时仍能识别 completed / skipped / failed / cancelled。
- 实现现状：`RepoNoteAIGenerationHeaderControl` 只显示当前步骤与 `n/7`，无法在折叠状态下分辨“下载 README 已完成”还是“已跳过”。
- 风险：直接削弱用户提出的“折叠标题行右侧流程可视化”。
- 修复：在标题行增加 7 个固定宽度微型状态符号，每个符号按步骤状态切换图标，并为整组补充辅助功能摘要。

### P1-02：缺少发起 AI 前的隐私明示

- 需求证据：正式方案 §9 要求发起前明示“README 和当前个人笔记将发送到用户配置的 AI Provider”；详细设计 §10.4 也把隐私说明列为展开面板第一项。
- 实现现状：生成面板直接显示步骤列表，没有这条说明。
- 风险：个人笔记是用户私有内容，即使是 BYOK，也应在主动发送前提供可见边界。
- 修复：在 AI 空闲态与生成面板中提供简短明示；不增加额外确认 sheet，保持操作轻量。

### P2-01：等待确认阶段少“重新生成”操作

- 需求证据：正式方案 §6.2 和详细设计 §10.4 均要求草稿完成后可“应用 / 重新生成 / 放弃”。
- 实现现状：`.awaitingConfirmation` 仅显示“放弃”和“使用此草稿”。
- 修复：在等待确认的操作组中增加“重新生成”，仍使用当前编辑 buffer 冻结新快照。

### P2-02：详细设计的文件路径与 API 名称漂移

- `Starcat/Features/AI/Usage/AIUsageModels.swift` 实际为 `Starcat/Core/Database/Models/AIUsageEvent.swift`。
- `AIDefaultPrompts.note` 实际为 `AIDefaultPrompts.repoNote`。
- `generateText` 设计为 private instance helper，实际为 internal static helper，以便使用假 `AIClientProtocol` 直接单测。
- `finishApplying()` / `failApplying(messageKey:)` 实际收口为 `finishApplying(success:)`，失败时回到可重试的 `.awaitingConfirmation`。

### P2-03：详细设计的可观察字段与实现不一致

- 文档写有 `wasReadmeDownloadRequired`，实现通过 `downloadingReadme` 的 completed / skipped 状态表达，没有重复 Bool。
- 实现新增 `preparedInput` 作为单测可观察的冻结输入，并用 `errorDetail` 补充受控本地错误描述，文档未记录。

### P2-04：详细设计中的 UI 文案列表超出实际首版

- 设计枚举了 `optimize` / `stop` / 独立 privacy key 等动作，实际使用 `generate` / `cancel` 和现有 AI 错误文案。
- 修复时以实际首版 key 为准，新增隐私说明 key，删除未实现的 key 清单描述。

## 3. 已确认无漂移项

- AI 只使用 README Markdown 与当前笔记快照，无 HTML / metadata / code context / external context。
- AI 预检早于 README 读取与下载。
- 草稿独立于 `editingContent`，用户确认前不写库。
- 既有笔记快照传入 Prompt，应用时存在冲突门禁。
- 复用 `repo_notes.is_ai_generated`，没有 schema 修改或 migration。
- 七步顺序、六种步骤状态与七种总体阶段一致。
- 专项 48 / 48 和全量 1732 项测试证据已记录，人工 UI 验收仍明确标为待执行。
- `docs/功能实现总览.md` 与 Changelog 均未越权修改。

## 4. 修复顺序

1. 补标题行七步微型状态和辅助功能摘要。
2. 补个人笔记发送隐私明示与等待确认的重新生成操作。
3. 回填详细设计的路径、API、状态字段、UI 和 i18n 清单。
4. 执行构建 / 专项测试后再关闭本报告问题。
