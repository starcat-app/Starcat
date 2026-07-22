# RepoContext 深度思考结果报告

> 日期：2026-07-17
> 状态：实现、自动化验证与四轮审查已完成
> 方案：`RepoContext深度思考实施方案.md`
> 清单：`RepoContext深度思考Checklist.md`

## 1. 最终结果

单项目 RepoContext 深度思考已完整接入知识库 RAG。它不是简单把 XML 拼进 Prompt，而是覆盖 Composer 授权、按会话草稿、执行状态机、独立预算与 Prompt 协议、Plan、时间线、Debug Trace、citation、Evidence Inspector、历史审计、i18n、隐私边界和测试。

四轮审查发现的问题均已修复，第 4 轮清洁复审无新增发现。最终 RAG 定向测试、全量测试、`Starcat` 与 `StarcatDirect` Debug build 均通过。

## 2. 五项需求落地

| 需求 | 最终实现 |
|---|---|
| Composer 顺序 | 固定为附件 → 联网搜索 → 深度思考 → 发送；深度思考使用 `brain.head.profile`，不显示常驻文本。 |
| 单项目门禁 | 恰好一个显式项目时才可开启；0 个或多个项目自动关闭；附件数量完全不参与判断。 |
| 持久化语义 | 与联网开关进入同一按会话、App 进程内存级 Composer 草稿；切换会话/重开工作台恢复，App 退出后不另建持久化真源。 |
| 独立 Prompt 协议 | Generator 使用 `{repoContextSection}`，不合并 `{evidenceSection}`；缺少新占位符的旧 Generator 配置直接恢复默认模板，不保留兼容双轨。 |
| 独立预算 | RepoContext 不使用 chunk `evidenceTokenBudget`、topK、per-repo cap 或 chunk hard cap；仍受 `aiRepoContextTokenBudget`、模型总窗口和输出预留约束，空间不足时执行 XML 感知投影。 |

## 3. 完整执行与展示链路

1. Composer 冻结唯一项目、深度思考开关、联网开关和附件快照。
2. Planner 只收到 RepoContext 能力与目标 identity，不接触 XML，也不能扩大项目范围。
3. Service 在本地检索之后、联网之前复用 `RepoAIContextProvider`，再次校验唯一项目。
4. Provider 复用既有 branch、archive、cache、RepoContextPacker 和 cleanup 流程。
5. Service 校验非空 XML 和正式 `<repository>` 根节点；projector 在无需投影和需要投影两条路径都执行相同 schema 校验。
6. 时间线展示 prepared、缓存/下载/打包真实进度、按模型总窗口 projecting、completed/degraded；投影失败不会伪报成功。
7. PromptBuilder 将实际 XML 投影放入独立 `{repoContextSection}`，并生成仓库级 `RAGCitationSource.repoContext`。
8. Plan 展示目标、原因、配置预算、outcome、commit、cache、原始/发送 token 与投影状态。
9. Evidence Inspector 使用独立 RepoContext 区，展示 XML 五行预览、全文 popover、复制反馈和审计字段；degraded snapshot 不伪装成 XML 证据。
10. 历史只保存 snapshot/citation；只有 repo、commit、原文 SHA-256 匹配时才按当轮 sentTokens 重建 XML 预览。

## 4. 数据与隐私边界

- XML 只在本轮内存态和用户已选择的 BYOK chat Provider 请求中流转。
- XML 不写 `rag_chunks`、notes、普通消息正文或 CloudKit，也不进入 External Search query。
- 会话持久化只保存 commit、hash、token、cache、outcome、projection 等审计元数据和 citation。
- RepoContext 专项 Debug stage 只保存摘要；最终 Prompt stage 可能包含实际发送 XML，并沿用既有本地 Debug 文件、清理和隐私提示。
- 本需求没有修改已发布 v7 RAG schema，也没有新增启动期旁路迁移。

## 5. 审查结果

| 轮次 | 范围 | 结果 |
|---|---|---|
| 第 1 轮 | 架构、预算、XML、证据门禁、取消、数据库与隐私 | 修复空/损坏 XML 伪成功和降级/取消/历史 round-trip 测试缺口。 |
| 第 2 轮 | Composer、草稿、时间线、Plan、Evidence、引用、历史、Debug | 修复投影前提前完成时间线和 degraded 空证据卡。 |
| 第 3 轮 | schema、测试、i18n、文档、专项进度、Checklist、工程门禁 | 修复无需投影时根节点漏校验、旧 Prompt 测试契约和 Home 测试异步门禁。 |
| 第 4 轮 | 清洁复审 | 无新增问题。 |

详细证据见 `RepoContext深度思考审查报告-第1轮.md` 至 `RepoContext深度思考审查报告-第4轮.md`。

## 6. 最终验证

- `xcodegen generate`：通过；生成后工程文件无差异。
- `jq empty Starcat/Resources/Localizable.xcstrings`：通过。
- `git diff --check`：通过。
- `String(localized:)` / `NSLocalizedString` 禁用调用扫描：只命中既有说明注释，无产品调用。
- `Starcat build-for-testing`：通过。
- RAG 定向 Suite：`KnowledgeRAGCoreTests`、`RAGChunkBuilderTests`、`RAGChunkRepositoryTests`、`RAGConversationHistoryWindowTests`、`RAGLocalizationTests` 全部通过。
- 全量 `Starcat test`：最终结果 `Passed`、0 failures；最后一次 xcresult 记录 1536 tests。
- `Starcat` Debug build：通过。
- `StarcatDirect` Debug build：通过。
- 没有新增产品代码 warning。`KnowledgeRAGCoreTests` 仍有既有 MainActor 测试 warning；另有一次 test host 在测试启动前被 signal kill，重跑后连续通过，完整边界已记入第 3 轮报告。

## 7. 提交记录

本专项使用中文 message 分步提交，未 push。主要序列如下：

- 方案与清单：`fd5da3d9`、`983eeb05`。
- 核心模型/Prompt/预算：`3b50e613`、`40647214`。
- Provider/Service/Debug：`ea58f526`、`55808939`。
- Composer/草稿：`c4cb113a`、`48ac3323`。
- Plan/时间线/引用/Evidence/历史：`9e5b2576`、`625b11a2`、`f35385d4`、`db47cbbb`。
- 测试与正式文档：`91ccd2a4`、`5ae906ca`、`f6e7bfa2`。
- 第 1 轮：`51905738`、`a1174b6c`、`d0c051ca`。
- 第 2 轮：`cc921288`、`88a167b6`、`4ea34bb4`。
- 第 3 轮及门禁修复：`6648b1bc`、`455c9945`、`e9177d65`、`3d2e8a1f`、`96fad56d`、`0c2a42ff`、`1acee3c6`。
- 第 4 轮清洁复审：`dda9b3e7`。

## 8. 已知边界与待确认项

- 本轮没有用真实用户数据库执行外部 AI/GitHub 问答，也没有把源码/自动化检查冒充人工 UI 点选验收。UI 行为由源码契约、read model 和定向测试覆盖；如需视觉验收，可在单项目会话中人工核对图标、时间线和 XML popover。
- `docs/功能实现总览.md` 受仓库铁律保护，本专项未写入。第 3 轮报告已提供 checkbox、`> 实现：` 和变更日志草案，等待 dong4j 明确说“可以写总览”后再同步。
- 当前工作区另有 `docs/功能实现总览.md` 与 `supports/starcat-site/appstore/index.html` 的并行改动，本专项未暂存、未提交。
- 未执行打包、发布、上传或 push。

## 9. Go / No-Go

自动化与工程审查结论：**Go**。RepoContext 深度思考功能完整、边界明确、文档与代码一致，没有阻止后续人工 UI 验收或合并的已知功能缺口。
