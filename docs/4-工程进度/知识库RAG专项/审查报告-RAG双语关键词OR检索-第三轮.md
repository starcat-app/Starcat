# RAG 双语关键词 OR 检索第三轮审查报告

> 审查日期：2026-07-17
> 审查范围：正式设计、专项进度、Checklist、提交历史与最终工程门禁准备
> 审查基线：`1a2cd1c`
> 结论：发现 2 项文档一致性问题和 1 项 worktree 构建问题；先记录后逐项修复
> 修复回填：3 项均已修复；全量测试与双 Debug target build 通过

## 1. 已核验证据

- `docs/功能实现总览.md` 未被本任务修改；专项进度与 Checklist 独立记录真实状态。
- `docs/1-立项/开发前问题清单.md` 已登记普通 AND / RAG OR、双语与 repo id scope 决策。
- 29 号设计明确普通搜索与 RAG 查询协议边界；30 号设计已加入 `keywordQueries`。
- 自任务基线后的所有提交均使用中文 message，每个方案、功能、测试、审查修复分别提交。
- 当前分支为 `codex/rag-bilingual-keyword-or`，未执行 push、打包、发布或上传。
- schema 与 migration 未修改，`v7-knowledge-rag` 收口边界保持不变。

## 2. 发现的问题

### R3-1：30 号正式设计仍残留不存在的 Retriever 伪类型

严重度：P2

§8.1 已把两个 Provider 签名更新为新协议，但同一代码块仍保留 `RAGRepoCandidateSet`、
`RAGRetrievalHit` 以及 `protocol RAGHybridFusionEngine` 等与当前实现不一致的草图类型。真实代码
使用 `[RAGRepoCandidate]`、`RAGChildHit`、`RepoContextBundle` 和具体
`RAGHybridFusionEngine` struct。继续保留会让维护者无法判断哪些是现行 API。

修复要求：把 §8.1 收敛为真实 Retriever/Provider 输入输出，不再混用早期伪类型；仅保留
当前代码中存在的核心字段。

### R3-2：3～8 个关键词的“目标”与“本地硬校验”口径未分开

严重度：P2

Prompt 要求模型生成 3～8 个关键词，但本地校验只执行去空、去重、低信息词过滤、repo identity
排除、单项 80 字符与最多 8 项；过滤后允许少于 3 项，不会为了凑数生成低质量关键词。
当前方案和 Checklist 容易被理解成执行层也强制最少 3 项，与代码不完全一致。

修复要求：所有正式文档统一写成“Prompt 目标 3～8 项；执行层硬上限 8，过滤后可少于 3”，
避免未来为了满足文档错误补词。

### R3-3：StarcatDirect Debug 依赖未跟踪的独立仓库

严重度：P1

最终门禁中 `StarcatDirect` 的 `Copy Changelog Resource` 失败。`project.yml` 硬编码读取
`supports/starcat-pro/CHANGELOG*.md`，但 `supports/starcat-pro` 是未被当前 Git worktree 跟踪
的独立仓库；干净 worktree 必然缺少该路径。根目录已有受 Git 跟踪的双语 CHANGELOG，
`Starcat` target 可正常使用。

修复要求：Direct Release 继续严格要求公开 `starcat-pro` 更新日志，避免错误发布内容；Debug
构建在独立仓库缺失时允许明确告警并回退根目录 CHANGELOG，使任意干净 worktree 可完成
编译与单测。修改 `project.yml` 后重新执行 `xcodegen generate` 并重跑 Direct Debug build。

## 3. 工程进度核对

- 专项进度新增两条完成项，且保留“真实中英混合评测集”未完成项，没有把合成单测冒充质量评测。
- Checklist 第一、二轮报告与修复提交均已回填。
- 全量 test 已通过 1547 项（1538 通过、8 跳过、1 预期失败、0 失败），`Starcat` Debug
  build 已通过；`StarcatDirect` 首次门禁因 R3-3 失败，尚不能勾选。
- 最终结果报告与总览拟同步文案尚未生成，属于后续收口步骤，不提前标记完成。

## 4. 修复后最终门禁

- 修正文档伪类型与 3～8 关键词口径。
- 执行 `git diff --check`、xcstrings JSON 与 i18n 静态检查。
- 执行 RAG 定向 Suite、全量 test、`Starcat` 与 `StarcatDirect` Debug build。
- 审查完整提交列表、分支 upstream 与 worktree clean 状态。
- 若工程门禁发现新问题，先提交门禁结果，再按小功能修复；之后增加最终无问题审查轮。

## 5. 修复回填

| 问题 | 修复证据 | 状态 |
|---|---|---|
| R3-1 | `42bee00` 将 §8.1 收敛为真实 Retriever、Provider、ChildHit、Bundle 与 Result 类型 | 已关闭 |
| R3-2 | `86cb951` 统一“Prompt 目标 3～8、本地硬上限 8、过滤后可少于 3” | 已关闭 |
| R3-3 | `e6742f0` 为 Direct Debug 增加干净 worktree changelog 回退，Release 保持严格阻断 | 已关闭 |

## 6. 最终工程门禁结果

| 门禁 | 结果 |
|---|---|
| 全量测试 | 1547 项：1538 通过、8 跳过、1 预期失败、0 失败 |
| `Starcat` Debug build | 通过 |
| `StarcatDirect` Debug build | 首次复现 R3-3；修复并重新 `xcodegen generate` 后通过 |
| xcstrings JSON | `rtk jq empty` 通过 |
| i18n 静态检查 | `String(localized:)` / `NSLocalizedString` 仅命中既有注释 |
| UI 颜色差异检查 | 本需求 Swift diff 未新增 `.tertiary` |
| Git whitespace | `rtk git diff --check` 通过 |

Direct Debug 在独立 `starcat-pro` 仓库缺失时输出一条预期资源回退 warning；没有新增 Swift
compiler warning。Release 不执行回退，缺少正式双语 changelog 时仍会失败，发布边界未放宽。

## 7. `docs/功能实现总览.md` 待确认草稿

本任务未修改受保护总览。若 dong4j 后续明确说“可以写总览”，建议在 RAG 对应章节补充：

```markdown
- [x] **RAG 双语关键词 OR 检索** — Planner 拆分语义查询与双语关键词，RAG FTS5 使用安全 OR，并补齐检索漏斗三态 — `KnowledgeRAGQueryPlanner.swift`、`RAGSearchProviders.swift`、`RAGWorkspaceInspector.swift` — 2026-07-17
> 实现：普通搜索继续 AND；RAG 关键词经本地去重、限长和转义后 OR 召回，repo 范围仅由 id 强制限定；Trace/Snapshot 不复制分片正文或原始外部错误。
```

建议 §10 变更日志草稿：

```markdown
- 2026-07-17 HH:MM: 完成 RAG 双语关键词 OR 检索与检索漏斗可解释性整改
```
