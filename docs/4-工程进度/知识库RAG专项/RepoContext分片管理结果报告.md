# RepoContext 分片管理结果报告

> 日期：2026-07-17
> 状态：代码、自动化、文档、四轮审查与 Checklist 已完成；人工真实大仓和 UI 点选待发布前验收
> 分支：`dev`
> Push：未执行

## 1. 交付结论

知识库详情现已把文件系统中有效的 RepoContext `context.xml` 展示为特殊托管分片：固定在 metadata 后成为第二项，独立显示 `0 / 1`，且不写入 `rag_chunks` 或普通索引统计。用户可复用现有分片编辑 sheet 编辑、校验、删除和下载 XML，也可在详情页主动生成或重新生成。

主动生成复用既有 `RepoAIContextProvider`，展示解析仓库、下载代码、生成 XML 三个真实阶段，不伪造百分比。当前 spinner 支持 hover / focus 切换为停止按钮；停止、切仓、筛选自动切仓、移出知识库和窗口关闭都会取消任务并只清理下载 `.tmp`，保留正式 ZIP 与旧有效 XML。

## 2. 已实现功能

- `RepoContextStorage` 提供 XML + metadata 一次性快照读取、`<repository>` 根节点校验、UTF-8 原子编辑保存和完整项目删除。
- 手工编辑刷新 token、字节数和最近访问时间，保留生成时间与生成次数；非法草稿不覆盖原文件。
- 知识库浏览器把 RepoContext 合并为展示层特殊项，固定在 metadata 后；缺 metadata 的旧数据置顶。
- RepoContext 使用独立 `0 / 1` 统计，不创建 `RAGChunkSource`，不参与普通分页、embedding、召回和覆盖率。
- RepoContext 行复用 `KnowledgeRAGChunkEditor` sheet，支持固定标题/路径、等宽正文、保存错误留窗和删除确认。
- 编辑器通过 XML `NSSavePanel` 下载当前草稿，包含未保存修改；取消静默，下载不修改缓存。
- 详情页支持生成/重新生成；全局代码上下文关闭时只引导前往 AI 设置，不自动修改用户设置。
- 生成状态覆盖 resolving、downloading、packing、succeeded、failed、cancelled；失败可重试，成功立即刷新第二项。
- generation UUID + repo id 双重校验阻止取消后或切仓后的迟到结果回写；生成期间阻止重复生成、RepoContext 编辑和删除。
- 新增固定文案均提供 en / zh-Hans，相关 sheet、focus、颜色、help 与 accessibility 按项目规范处理。

## 3. 自动化验证

- `RepoContextStorageTests`：9 项通过，覆盖阶段映射、请求身份、切仓状态、第二项顺序、独立统计、下载缓存不变、合法/非法编辑、metadata 和删除。
- `RepoContextStorageTests + SharedSnapshotServiceTests + KnowledgeRAGCoreTests`：157 项 / 3 suites 通过。
- 全量 Swift Testing：1503 项 / 176 suites 通过，0 失败，1 个项目既有 known issue。
- `Starcat` Debug build：通过，quiet 输出无 warning/error。
- `StarcatDirect` Debug build：通过，quiet 输出无 warning/error。
- `xcodegen generate`：通过。
- `jq empty Starcat/Resources/Localizable.xcstrings`：通过。
- RepoContext en / zh-Hans 完整性、禁用 i18n API 扫描、`git diff --check`：通过。

测试期间有一次 Xcode LaunchServices launcher `childPID > 0` 断言，命令退出但没有执行测试；没有将其记为通过，立即重跑后 RepoContext 8 项真实执行并通过。最终 9 项、157 项和全量 1503 项均为后续真实执行结果。

## 4. 四轮审查

### 第 1 轮：架构、数据与取消边界

- 发现筛选/搜索自动替换选中仓库时旧生成没有取消，以及过期结果身份缺少专项测试。
- 通过程序化切仓取消和 `RepoContextGenerationIdentity` 双身份断言修复。

### 第 2 轮：UI、功能完整性与 i18n

- 发现成功/失败后切仓会残留上一仓库提示。
- 生命周期重置改为无条件回到 idle，并覆盖五类状态测试。

### 第 3 轮：测试、文档与工程进度一致性

- 发现下载缓存不变和 `0 / 1` 独立统计的 Checklist 证据不足。
- 补齐真实 fixture 导出前后对比，抽取独立统计纯函数并测试；随后完成全部最终门禁。

### 第 4 轮：清洁复审

- 未发现新增 P0 / P1 / P2 问题；前三轮共 2 个 P1、3 个 P2 均已修复并回填。

## 5. 本需求提交

- `c99330a7 docs(rag): 新增 RepoContext 分片管理方案与清单`
- `3b816d4c feat(rag): 补齐 RepoContext XML 存储管理能力`
- `00aab142 feat(rag): 展示并管理 RepoContext 特殊分片`
- `51d8cf4d feat(rag): 支持下载 RepoContext XML 草稿`
- `87bdb5b5 feat(rag): 支持主动生成并取消 RepoContext XML`
- `effaaba6 docs(rag): 同步 RepoContext 分片管理设计与进度`
- `e5a8de8c docs(rag): 新增 RepoContext 分片管理第一轮审查报告`
- `c63e0935 fix(rag): 修复 RepoContext 自动切仓取消竞态`
- `3a439e83 docs(rag): 回填 RepoContext 第一轮审查结果`
- `e5d6d380 docs(rag): 新增 RepoContext 分片管理第二轮审查报告`
- `c8522463 fix(rag): 清理 RepoContext 切仓后的旧提示`
- `47267bf2 docs(rag): 回填 RepoContext 第二轮审查结果`
- `533994b8 docs(rag): 新增 RepoContext 分片管理第三轮审查报告`
- `3b509a55 test(rag): 补齐 RepoContext 下载与独立统计证据`
- `b2caff96 docs(rag): 回填 RepoContext 第三轮审查与门禁结果`
- `ce4503cb docs(rag): 新增 RepoContext 分片管理清洁复审报告`

所有本需求提交使用中文 message，未 push。执行期间另一项并行工作提交了 `24312322 feat(rag): 新增 Debug Payload 后台分块展示与测试`，不属于本需求提交清单。

## 6. 已知边界与人工验收

以下项目无法由本地单元测试替代，本轮明确保留为发布前人工验收，不伪造完成：

- 选择一个真实大仓，观察首次下载耗时、三阶段切换和停止响应。
- 分别验证已有 XML 与无 XML 项目的第二项位置、编辑、非法保存留窗、删除确认和重新生成。
- 验证下载 sheet 默认文件名、未保存草稿内容与取消操作。
- 关闭全局代码上下文后验证 AI 设置引导。
- 观察生成期间行编辑、删除和重复生成入口确实不可操作。

复审结束时工作树另有“知识库索引概览信息密度”相关的控制器和 localization 未提交改动；本需求没有暂存、回退或归入结果提交，当前构建和静态检查已包含其工作树状态并通过。

## 7. `docs/功能实现总览.md` 待确认同步草案

本轮未修改 `docs/功能实现总览.md`。若 dong4j 后续明确允许同步，建议增加：

`- [x] **RepoContext 分片管理** — 已有 XML 固定展示为 metadata 后第二项，支持编辑、删除、下载、主动生成、阶段进度与取消 — \`KnowledgeRAGWorkspaceWindowController.swift\` / \`RepoContextStorage.swift\` — 2026-07-17`

紧跟：

`> 实现：RepoContext 保持文件真源并作为特殊托管项展示，不写 rag_chunks；生成复用 RepoAIContextProvider，取消只清理 .tmp 并保留正式缓存。人工真实大仓与 UI 点击仍按结果报告列为待验收。`

建议变更日志草案：

`- 2026-07-17 22:50: 完成知识库 RepoContext 第二项管理、主动生成、进度取消与 XML 下载`
