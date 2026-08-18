# AI 流式正文卡顿优化方案

> 创建时间：2026-08-19
> 状态：讨论已收敛，待 dong4j 确认开干。本文只记录方案，未改代码。
> 前置：RAG 思考与主窗口 AI 对话 Think 已改为固定高度 `NSTextView` 追加渲染，正文 `liveTail` 未动。

---

## 1. 问题

Think 改完之后，长推理不再把主线程拖死。长**正文**仍会卡，根因和 Think 改前是同一类，但不能用同一套产品形态去修。

Think 可以只露一段尾巴：用户接受固定约 12 行视口，外层对话 `ScrollView` 高度锁死。正文必须让完整答案在长，这是产品约束。把 Think 视口原样套到正文，等于生成过程中只能看见末尾十几行，不可接受。

## 2. 现状：正文已经做了一半

主窗口 AI 对话与 RAG 回答共用 `StreamingMarkdownSnapshot` / `StreamingMarkdownAssembler`（`Starcat/Features/AI/StreamingMarkdownSnapshot.swift`）。

当前流式链路：

- 大约每 700 字、且碰到围栏外空行，冻结成一段 Markdown，后续 token 不再重解析该段。
- 未闭合尾巴 `liveTail` 用 SwiftUI `Text` 展示，ViewModel 大约 10Hz（对话）或 15Hz（RAG）把**完整尾巴字符串**写进 `@Observable` 快照。
- 外层是 `ScrollView` + `VStack`。对话侧有意不用 `LazyVStack`：长 Markdown 进出可视区时惰性测量会校正 content offset，表现为跨消息跳跃。

相关 UI：

- 对话流式气泡：`AIStreamingChatBubble`（`Starcat/Features/AI/AIChatBubble.swift`）
- RAG 流式回答：`RAGStreamingAssistantMessageBlock`（`Starcat/Features/RAG/UI/RAGAssistantMessageBlock.swift`）
- 快照发布：`RepoAIChatViewModel`、`KnowledgeRAGWorkspaceViewModel`

冻结 chunk 已经挡住「每个 token 整篇 MarkdownUI 重解析」。剩下的成本和改前 Think 对齐：增长字符串进属性图、SwiftUI `Text` 整段替换、外层 `VStack` 跟着测高。

AI 摘要是另一条更脏的路：`RepoAIInsightViewModel.streamingSummaryText` 每个 delta 把**整篇**交给 `RepoAISummaryMarkdownView`，没有 chunker，也没有 liveTail。不在本方案第一刀里。

完成后把整篇 Markdown 一次性交给 MarkdownUI（含代码高亮）是另一类「顿一下」，和流式跟手分开处理。

## 3. Think 已经验证的两条胜因

Think 卡顿来自两件事，都修了：

1. 增长字符串进入 `@Observable`，SwiftUI `Text` 对整段做 CoreText 重排。
2. 外层对话 `ScrollView` 每个 token 重新测高。

正文可以复用第 1 条（session 追加、字符串不进属性图）。第 2 条不能用固定 12 行去消灭，只能减轻：允许正文视口按内容长高，让高度变化变成 TextKit 自己长、加上偶尔冻一段 Markdown，而不是每 10Hz 整段 `Text` 测高。

## 4. 方案对比

| 方案 | 做法 | 工作量 | 风险 | 流式跟手 | 产品观感 |
|------|------|--------|------|----------|----------|
| 0. 只降频 | 10Hz 改 5Hz，或加大立即提交字数 | 很小 | 低 | 有限。尾巴一长，`Text` 整段替换仍然变贵 | 不变，输出更一截一截 |
| A. liveTail 走 append，允许长高 | 文本真源进 `RAGStreamingPlainTextSession`；快照不再带增长字符串；尾巴用 `NSTextView` 只追加；已冻结 Markdown 保留 | 中，复用 Think 已落地的 session | 中低：要对齐 `.bodyEmphasis` 字号和行高 | 明显好于现在。外层仍会随高度上台阶 | 流式期与现在一致：已冻结段是 Markdown，尾巴是纯文本 |
| B. 流式全程纯文本，完成再 Markdown | 流式只 append，结束换一次 MarkdownUI | 中 | 高 | 最好 | 流式看不到标题、列表、代码高亮 |
| C. 底部固定输出窗 | 正在生成的正文放进固定最大高度的内滚区域 | 大 | 高 | 外层测高基本消失 | 不像聊天气泡，更像终端 |

方案 0 只能当垫步，不能当终点。方案 B 的流式观感退步太大。方案 C 先改交互，不该当第一刀。

**选定 A。** Think 已经证明「字符串不进属性图 + TextKit 只追加」能把主线程救回来。正文已经有冻结 chunk，缺的就是对 `liveTail` 做同一件事，并且视口按内容长高。

## 5. 方案 A 怎么落地（仍未实施）

### 5.1 运行中

- 每个正文 delta 只 `session.append`，禁止把增长 `liveTail` 赋给 `streamingPresentation`。
- 快照只发布：已冻结 `stableMarkdownChunks`、`revision`、以及不含增长文本的元数据。新冻一段 Markdown 时才需要让 SwiftUI 知道 chunk 数组变了。
- `liveTail` 用可长高的 `NSTextView`（复用 `RAGStreamingPlainTextSession`），不是 Think 的 12 行锁高。
- 字号走 `.bodyEmphasis`（对话现状 14pt 档），与改前 `Text(snapshot.liveTail)` 对齐；颜色走正文主色，不要误用 Think 的 `secondaryLabelColor`。
- 已冻结 chunk 继续 MarkdownUI + Equatable，行为不变。

未闭合代码块、或模型很久不空行时，尾巴仍可能很长。那正是 A 要扛住的路径：TextKit 追加是 O(delta)，不再对整段 `liveTail` 做 SwiftUI 布局。

### 5.2 完成后

- 落库仍用 assembler / 累积全文，语义不变。
- 流式气泡卸掉后，历史气泡仍走现有完整 Markdown，本轮不改完成态渲染。
- 折叠再展开不复用运行中 `NSTextView` 绑定（Think 已经踩过：复用会空白）。正文完成后直接切历史气泡，没有「展开空白」这条路径，但仍不要把运行中 session 的 view 留到完成态。

### 5.3 外层滚动

- 对话继续 `VStack`，不改回 `LazyVStack`。
- Think 完成后不再撑高，正文长高仍触发贴底。现有 `onChange(of: streamingPresentation?.revision)` 可以保留，但 revision 应变为「冻 chunk / 阶段切换」，而不是 10Hz 文本刷新。
- 用户主动上滚后仍由 `ScrollTailController` 拒绝抢滚。

## 6. 四个攻击角

- **依赖**：不新增服务，就是现成 AppKit 与已落地的 `RAGStreamingPlainTextSession`。
- **放大 10 倍**：先坏的是完成后整篇 Markdown 高亮，不是流式 append。若两三千字带大代码块完成时仍会顿，再单独做「完成后也保持分块 Markdown」。
- **回滚**：只动流式气泡；完成态、落库、history prompt 不变。回退就是恢复 `liveTail` 进快照 + SwiftUI `Text`。
- **前提若错**：若卡顿 90% 来自外层 `VStack` 测高而不是 `Text`，A 只能拿到 Think 大约一半的收益。那时再评估方案 C，或把整列对话换成 AppKit 列表。先做 A 才能验证这条前提。

## 7. 范围与分期

本方案**第一刀只改主窗口 AI 对话正文**（与刚验收的 Think 同一块产品表面）。

RAG 与对话共用 `StreamingMarkdownSnapshot`。A 的 liveTail 视口抽一层之后，RAG 可以跟，但不要和对话绑死同一天改。RAG 侧还有 2026-07 的限频 / 观察边界 / 8,000 字 Think 窗口清单（见下方相关文档），跟的时候要对齐，不要把旧限频假设写回对话。

AI 摘要单独排期：路径是整篇 `streamingSummaryText` + 整篇 MarkdownUI，比 liveTail 更脏，也不是用户这次卡住的那条对话气泡。

建议确认开干时三选一：

1. 只改对话 liveTail（推荐作为第一刀）
2. 对话 + RAG 一起（共用视口组件，两处 ViewModel 都停止发布 liveTail 字符串）
3. 摘要也排上（不建议与 1 捆在一起）

## 8. 明确不做

- 把正文锁成 Think 那样的固定 12 行视口
- 方案 B：流式期取消 Markdown 冻结 chunk
- 方案 C：底部固定输出窗 / 终端形态
- 外层改 `LazyVStack`
- 完成后整篇 Markdown 分块（属后续，见 §6）
- Agent 工作台（产品约定原始 reasoning 不进 Run Surface；正文路径也不在本轮）
- 改 `docs/功能实现总览.md`（落地并经验收后，由 dong4j 确认再写）
- 未说开干之前改任何代码

## 9. 待实施时的验收

人工（必须）：

- 主窗口对一个会长回答、且含未闭合代码块或很少空行的问题：流式应跟手，外层滚动在贴底时跟上，主动上滚后不抢位置。
- 已冻结段落保持 Markdown（标题、列表、链接、已闭合代码块）。
- 尾巴纯文本，完成后整条恢复完整 Markdown，落库内容与现在一致。
- 字号、行高、主色与改前 liveTail `Text` 观感接近，不要变成 Think 的 secondary 灰字。

单测：

- session 对正文 delta 立即累积全文；空片段忽略。
- ViewModel / assembler：冻 chunk 的边界不变；完成态全文与现在一致。
- 现有 `StreamingMarkdownSnapshotTests` 继续通过。buffer 的 10Hz 行为可以保留给未改路径，对话正文 UI 不再依赖把 `liveTail` 写进快照。

## 10. 相关代码与文档

代码：

- `Starcat/Features/AI/StreamingMarkdownSnapshot.swift`
- `Starcat/Features/AI/RepoAIChatViewModel.swift`
- `Starcat/Features/AI/AIChatBubble.swift`（`AIStreamingChatBubble`）
- `Starcat/Features/AI/RepoAIWindowContentView.swift`
- `Starcat/Features/RAG/UI/RAGStreamingPlainTextView.swift`（已有 session / 视口，正文需长高与主色变体）
- `Starcat/Features/RAG/UI/RAGAssistantMessageBlock.swift`（RAG 跟随时）
- `Starcat/Features/RAG/UI/KnowledgeRAGWorkspaceViewModel.swift`（RAG 跟随时）
- `Starcat/Features/AI/RepoAIInsightViewModel.swift`（摘要，不在第一刀）

文档：

- [`RAG流式渲染性能优化Checklist.md`](../../4-工程进度/知识库RAG专项/RAG流式渲染性能优化Checklist.md)（RAG 15Hz/10Hz、观察边界、滚动锚点；Think 运行态曾限 8,000 字，主窗口对话 Think 已改为固定视口，不再走该窗口）
- 主窗口对话 Think 与 RAG 思考视口已在代码中落地，无单独方案文档；本文件只管正文。
