# RAG Wiki 元数据结果报告

> 完成日期：2026-07-17  
> 分支：`codex/rag-wiki-metadata`（基于 `dev@eeaffc49`）  
> Worktree：`/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-rag-wiki-metadata`  
> 状态：代码、文档、Checklist、五轮审查与自动化门禁完成；未 push

## 1. 最终结果

本专项没有抓取 Wiki 正文，也没有新增 Wiki 分片或数据库 schema。Starcat 现在只探测公开仓库在 DeepWiki、ZRead、CodeWiki 的收录链接，通过统一 cache-first 服务和有界后台任务补齐，再把有效 URL 写入仓库现有唯一 `metadata:0`。

当 RAG 最终使用某个仓库时，Retriever 会批量附加该仓库完整 Metadata。Prompt 以全局两阶段方式先保留所有可容纳仓库的 Metadata，再加入普通分片；Metadata 缺失或历史排除时才使用 compact fallback。Metadata 不新增 hit、score、citation 或 `{metadataSection}`，RepoContext 的独立 placeholder / budget 不受影响。

知识库浏览器中的 Metadata 仍可查看、编辑，但 UI、ViewModel/domain 与 Repository 均禁止排除和永久删除。固定 Wiki 行会显示为可点击按钮；详情和全局搜索在冷缓存刷新完成或缓存清空后原地更新链接。

## 2. 已交付能力

### Wiki cache-first 与后台补齐

- 详情、搜索、Repo AI、Companion、启动扫描、新入库统一经过 `WikiContextService`；
- fresh 只读，stale 返回旧值并刷新，miss 返回空值并探测；
- 小并发队列、pending / in-flight repo 去重、失败静默降级；
- 私有仓库不出站；账号 / 数据库切换取消旧任务并使用 generation 阻断延迟写入；
- cache save/reset 事件携带仓库 identity，详情/搜索原地更新，索引器精确刷新 Metadata。

### Metadata 与 Prompt

- `RAGMetadataSnapshot` 读取本地 Wiki cache，Builder 固定输出 DeepWiki → ZRead → CodeWiki；
- `metadata:0` 保持 `keyword_only`，索引构建不等待 Wiki 网络；
- Retriever 在最终 repo limit 后批量读取有效完整 Metadata；
- 完整优先、compact fallback、Metadata 命中不重复、`structured_only` 维持 compact；
- 所有可保留仓库 Metadata 先于任意普通分片，Metadata 不做字符级截断；
- Metadata 不制造 citation；LLM 可直接看到 URL 并继续使用现有 Markdown 外链。

### 浏览器管理与 UI

- Metadata 行不显示删除按钮；多层防线拒绝新排除与永久删除；
- 保存 override 仍可用，并能恢复历史 soft-excluded Metadata；
- Wiki 按钮只解析固定 provider 与 `http` / `https`，通过 `NSWorkspace` 打开；
- plain button 补齐 focus 规范，文字颜色使用 `.primary`；普通分片删除/恢复路径不变。

## 3. 自动化验证

| 门禁 | 结果 |
|---|---|
| Wiki / DiskWikiCache / RAGChunkBuilder / Repository / Prompt-Retriever / Companion 定向测试 | 通过 |
| 全量 `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test` | 通过 |
| `Starcat` Debug build | 通过 |
| `StarcatDirect` Debug build | 通过 |
| `jq empty Starcat/Resources/Localizable.xcstrings` | 通过 |
| 新增 Swift 禁用 i18n 调用扫描 | 无命中 |
| 修改提交前 `git diff --check` | 通过 |
| 工作区 / push | clean / 未 push |

`StarcatDirect` 在独立 Starcat worktree 首次构建时因 ignored 的 `supports/starcat-pro` 缺失而失败；第 3 轮报告先记录后，以本机 `starcat-pro@6b1d8f2` 建立 detached 依赖 worktree，重跑通过。该依赖目录未进入任务 diff。

已知非本需求 warning：`KnowledgeRAGCoreTests` 的既有 `@MainActor shouldOfferExternalSearchSettings` 测试诊断仍会输出，但不影响测试通过，本专项未扩大修改。

## 4. 五轮审查结果

| 轮次 | 重点 | 发现与结果 |
|---|---|---|
| 第 1 轮 | Wiki 数据流与生命周期 | 修复 reset 监听吞取消；补 save/reset payload 测试 |
| 第 2 轮 | Prompt、UI、兼容语义 | 修复 Metadata 全局预算顺序；补详情/搜索原地回填与关键分支测试 |
| 第 3 轮 | 测试、文档、工程门禁 | 补新入库与精确路由测试；同步两阶段文档；补齐 Direct 构建依赖 |
| 第 4 轮 | UI 规范复验 | 修正 Wiki 链接 foreground 颜色语义 |
| 第 5 轮 | 最终逐项审查 | 无新增功能缺口，无阻断问题 |

详细证据见同目录 `RAG-Wiki元数据审查报告-第1轮.md` 至 `RAG-Wiki元数据审查报告-第5轮.md`。

## 5. 关键提交

- `0084d73c`：统一缓存优先查询与有界刷新；
- `2578c1fe`：后台补齐与切库屏障；
- `addfd5a8`：Wiki 链接写入仓库 Metadata；
- `347e923e`：最终 bundle 附加完整 Metadata；
- `0c9f2622`：Metadata 禁删与 Wiki 链接 UI；
- `50d26469`、`b11a4501`：Metadata-first 预算与全局两阶段装配；
- `8b649b4d`：详情/搜索冷缓存完成后原地回填；
- `bf7366cc`：新入库与精确重建路由测试；
- `2e62032b`：Wiki 链接 UI 颜色规范修复。

所有小功能、测试补齐、审查报告和审查修复均使用中文 commit message；没有 push。

## 6. 人工验收边界

以下真实 UI / 网络行为无法由当前命令行自动化观察，已明确保留，不伪造完成：

- Metadata Wiki 按钮视觉与真实系统浏览器跳转；
- 编辑 Metadata 后禁删状态、普通分片删除/恢复视觉；
- 真实知识库冷缓存补齐后的详情、搜索、Metadata 行更新；
- 私有仓库真实网络日志中的 Wiki 零出站。

## 7. `docs/功能实现总览.md` 待确认同步草案

本任务遵守仓库铁律，没有修改 `docs/功能实现总览.md`。如 dong4j 后续明确允许同步，建议在 RAG 对应章节新增：

```markdown
- [x] **RAG Wiki 链接与仓库完整 Metadata** — 公开 Wiki 收录链接经 cache-first 后台补齐写入 metadata:0，命中仓库完整 Metadata 优先进入 evidence，Metadata 多层禁删 — `Starcat/Features/AI/WikiContextService.swift` / `Starcat/Core/RAG/RAGChunkBuilder.swift` / `Starcat/Features/RAG/Core/KnowledgeRAGRetriever.swift` — 2026-07-17
> 实现：Wiki 只探测公开链接且私有仓库不出站；Retriever 为最终仓库附加完整 Metadata，Prompt 先全局保留 Metadata 再装配普通分片；知识库浏览器允许查看编辑 Metadata，但禁止排除和永久删除。
```

同时按主索引规则更新对应章节状态、顶部进度仪表盘和 §10 一条不超过 80 字的变更日志；执行前仍需 dong4j 单独确认“可以写总览”。
