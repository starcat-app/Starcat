# RAG 双语关键词 OR 检索第五轮审查报告

> 审查日期：2026-07-17
> 审查范围：代码、文档、测试、工程进度、隐私、Git 与最终交付完整性
> 审查基线：`2d35454`
> 结论：通过；未发现遗留功能缺口或阻断项

## 1. 功能完整性

- Planner 已拆分 `semanticQuery` 与双语 `keywordQueries`，官方默认 Prompt 可兼容升级。
- 普通搜索继续 AND；RAG 专用构造器安全转义并显式 OR，空 terms 不访问任何下游。
- 中文问题的默认协议同时覆盖中文概念与英文技术词；FTS5 本身不冒充翻译能力。
- 单仓库、多仓库、`.prefer`、`.exclude` 继续由 repo id 强制限定，repo 名不进入 FTS 必选词。
- Keyword/Vector 并行、双向独立降级、Rerank 继续使用语义查询。
- Plan 展示实际关键词；Trace 保存安全查询；Snapshot 只保存稳定 failure code。
- 漏斗能区分实际 0 命中、provider 失败和未执行跳过；`noCandidates` / `noReadyChunks`
  不再伪装成 0 命中。

## 2. 兼容与隐私

- 旧 Query Plan、旧 Retrieval Trace、旧 Snapshot 与旧 Diagnostics 缺少新增字段均有直接测试。
- 未修改 schema/migration，未回写 `v7-knowledge-rag`，不要求删库或重建数据库。
- 历史会话不保存原始 provider 错误、endpoint 或分片正文；当前 Debug 保留排障详情。
- 自定义 Planner Prompt 不覆盖；缺少关键词时使用有界 OR fallback。
- 私有 repo 仍只走本地 Provider，本次没有扩大网络发送范围。

## 3. 文档与工程进度

- 实施方案、29/30 号正式设计、开发前决策、RAG 专项进度与代码字段、范围、降级一致。
- Prompt “目标 3～8 项”和本地“硬上限 8、过滤后可少于 3”口径一致。
- 真实中英混合质量评测仍在专项进度中保持未完成，没有用合成单测冒充真实评测。
- `docs/功能实现总览.md` 未修改；待确认草稿已写入第三轮报告。
- 前四轮报告均遵守“先报告、后修复、再回填”，所有发现均关闭。

## 4. 工程门禁

| 门禁 | 最终结果 |
|---|---|
| RAG 定向 Suite | 通过 |
| 全量 test | 1547 项：1538 通过、8 跳过、1 预期失败、0 失败 |
| `Starcat` Debug build | 通过 |
| `StarcatDirect` Debug build | 通过 |
| xcstrings JSON / i18n | 通过 |
| Git whitespace | 通过 |
| UI 颜色 diff | 未新增 `.tertiary` |

`StarcatDirect` Debug 在独立 `starcat-pro` 仓库缺失时有一条预期资源回退 warning；Release
仍严格要求正式双语 changelog。没有新增 Swift compiler warning 或 error。

## 5. Git 与交付边界

- 分支：`codex/rag-bilingual-keyword-or`，基于 `dev@eeaffc49`。
- worktree：`/Users/dong4j/orca/workspaces/Starcat/rag-bilingual-keyword-or`。
- 所有小功能、测试、审查报告与修复均为独立中文 commit。
- 分支无 upstream、远端无同名任务分支，未 push。
- 未执行打包、发布、上传或部署。

## 6. 最终判断

本次约定范围内的功能、自动化、文档和工程收口均已完成。没有遗留代码缺口；剩余的真实
中英混合质量评测属于既有专项持续评测项，不是本次功能实现缺失。真实 LLM + 本地知识库的
人工 UI 点选未在自动化审查中伪造，建议合并后由 dong4j 用实际 Provider 做一次体验验收。
