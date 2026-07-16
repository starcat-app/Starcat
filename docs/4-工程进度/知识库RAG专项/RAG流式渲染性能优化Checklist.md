# RAG 流式渲染性能优化 Checklist

> 状态：第五阶段已完成（24 / 24 项完成）
>
> 范围：实施流式发布、SwiftUI 观察边界、尾部滚动和历史会话渲染窗口；数据库仍一次读取完整会话，窗口只限制 SwiftUI 实际布局的消息。

## 成功标准

- 正文流式快照严格不超过 15Hz，首个 delta 立即展示，结束时完整收口。
- Think 流式展示严格不超过 10Hz，运行中只渲染最近 8,000 字符，完整文本仍用于完成态与持久化。
- 总耗时和运行步骤耗时由标签内局部时钟推进，不依赖 Provider delta 到达。
- `RAGWorkspaceAnswerSurface` 不再直接读取高频 `streamingPresentation` 与 `executionSteps`。
- 流式尺寸变化不再通过 `onGeometryChange → @State → scrollTo` 形成反馈环。
- 用户停留底部时继续自动贴底；主动上滚后不抢位置；滚到底部按钮仍能抵达永久 sentinel。
- 相关单测与 Knowledge RAG 核心回归通过，本次相关文件的 `git diff --check` 通过。

## 第一阶段：限制流式发布与文本布局

- [x] 正文 UI 发布改为严格 8Hz，删除字符阈值绕过稳定限频。
- [x] Think UI 发布改为严格 5Hz，首个 delta 与最终 flush 不丢内容。
- [x] 运行中 Think 使用 8,000 字符有界窗口，完整文本继续保留。
- [x] 补充严格限频、有界展示和最终完整文本的单元测试。

## 第二阶段：隔离 SwiftUI 观察边界

- [x] 抽出独立的流式 Assistant 子视图，由它读取高频快照、执行步骤与计时。
- [x] Answer Surface 根视图与历史消息不再订阅正文 revision。
- [x] 保留稳定 Markdown chunk 的 Equatable 边界，避免冻结段落重复解析。
- [x] 执行步骤只让发生变化的行承担正文重排，其他步骤保持稳定。

## 第三阶段：移除滚动布局反馈环

- [x] 滚动任务合并与动画意图移入 `ScrollTailController` 的 `@ObservationIgnored` 状态。
- [x] 删除时间线整体高度 `onGeometryChange` 监听和 5Hz 主动 `scrollTo`。
- [x] 跟随状态使用 `.defaultScrollAnchor(.bottom, for: .sizeChanges)` 处理内容尺寸变化。
- [x] `ScrollViewReader` 仅用于历史恢复、滚到底部按钮与大纲导航等低频动作。
- [x] 补充滚动调度状态机测试，并完成针对性与核心回归。

## 第四阶段：历史会话按轮窗口化

- [x] 打开历史会话时只渲染最新 2 轮，轮次以 user 消息作为稳定起点。
- [x] 顶部手动入口每次加载更早 10 轮，继续使用准确高度的非惰性 `VStack`。
- [x] 当前会话新增问答时保留已展示轮次，不让旧内容在回答落库后突然消失。
- [x] 加载更早轮次后恢复原首条可见消息位置，避免内容向下跳动。
- [x] 大纲点击未渲染轮次时先扩展窗口，再定位对应 user message。
- [x] Prompt 历史、引用聚合、复制全部、导出和持久化继续读取完整消息数组。
- [x] 补充轮次边界、分批加载、大纲扩窗与滚动回归测试。

## 第五阶段：刷新流畅度回归整改

- [x] 运行中步骤耗时使用局部时钟刷新，不再依赖 reasoning delta 或 `executionSteps` 重绘。
- [x] 回答总耗时使用局部秒级时钟刷新，Provider 暂停输出时仍持续读秒。
- [x] 正文严格刷新上限由 8Hz 调整为 15Hz，Think 由 5Hz 调整为 10Hz；保留首包立即显示、最终 flush、8,000 字窗口和稳定 Markdown chunk。
- [x] 补充计时与刷新上限回归测试，运行定向 Suite 与两个 App target 编译。

## 验证结果

- 2026-07-15：`StreamingMarkdownSnapshotTests` + `ScrollTailControllerTests` 共 26 项通过。
- 2026-07-15：`KnowledgeRAGCoreTests` 共 101 项通过。
- 2026-07-15：`RAGConversationHistoryWindowTests` + `ScrollTailControllerTests` 共 18 项通过；并行测试启动器异常后以 `-parallel-testing-enabled NO` 稳定重跑。
- 2026-07-15：`xcodegen generate`、编译与本次相关文件的 `git diff --check` 通过；真实长流 UI 仍需人工体验验收。
- 2026-07-16：`KnowledgeRAGCoreTests` 121 项通过，覆盖运行中时钟与冻结耗时规则。
- 2026-07-16：`StreamingMarkdownSnapshotTests` 15 项通过，覆盖 15Hz / 10Hz 严格上限、大 delta 不绕过与最终完整性。
- 2026-07-16：`Starcat` 与 `StarcatDirect` 两个 scheme 编译通过，本次相关文件的 `git diff --check` 通过。

## 明确不在本次范围

- 改用 `NSTableView` / `NSCollectionView` 等 AppKit 容器。
- 改变 RAG 回答、推理、引用或持久化语义。
