# RAG Wiki 元数据审查报告（第 3 轮）

> 审查日期：2026-07-17  
> 审查范围：测试矩阵、i18n、实施方案、详细设计、专项进度、Checklist、提交与工程门禁  
> 审查结论：发现 2 个 P1、1 个 P2，均已修复；全量测试与双 target Debug build 通过

## 已核对

- `Localizable.xcstrings` JSON 合法；Metadata 系统管理错误文案具有 en / zh-Hans 翻译。
- 本分支新增 Swift 代码没有引入 `String(localized:)` 或 `NSLocalizedString(...)` 调用。
- 未新增 RAG schema / migration / Wiki source / Prompt placeholder / Debug stage，符合 v7 已收口边界。
- `docs/功能实现总览.md` 仅只读核对，分支无修改；最终报告只能提供待 dong4j 确认的同步草案。
- 当前 19 个提交均为中文 message，并按文档、缓存、补齐、Metadata、Prompt、禁删/UI、测试和审查修复拆分；未 push。
- 第一、二轮报告均遵守“先报告、再修复、再回填”。

## 发现项

### P1：Checklist 声称的新入库与精确重建测试尚未形成直接证据

后台测试覆盖启动扫描和切库取消，但尚未直接发送 `.repoLibraryStateDidChange` 验证新仓库入队。缓存测试锁定了 save/reset payload，却没有让 `KnowledgeRAGIndexBuilder` 使用同一个可测试的事件路由，因此 owner/repo 或 repositoryKeys 的解析变化仍可能让精确重建静默失效。

修复要求：

1. 增加“新仓库加入知识库后入队并写缓存”测试；
2. 抽出最小的 Wiki Metadata 事件路由纯函数，让 builder 的 save/reset 监听复用；
3. 增加 change 精确单仓、reset 多仓与非法 payload 忽略测试；
4. 通过后才能勾选 Checklist 的 Metadata 精确重建测试项。

> 修复状态：已完成。新增新入库通知测试与 change/reset 纯事件路由测试，builder 复用同一路由，提交 `bf7366c`。

### P2：正式设计文档未精确反映第二轮修复后的两阶段语义

详细设计仍写成“先试放仓库完整 Metadata，再逐段加入普通证据”，容易被理解为逐仓库交错装配；它没有明确“所有可保留仓库 Metadata 先于任意普通分片”。方案和详细设计也未记录 cold miss 完成后详情 / 搜索原地回填、缓存清空时移除旧链接。

修复要求：同步实施方案、详细设计和专项进度，明确两阶段全局优先级与前台 save/reset 事件行为。

> 修复状态：已完成。三处文档明确全局两阶段预算与详情/搜索原地回填，提交 `c1acc16`。

### P1：独立 worktree 缺少 StarcatDirect 的本地 `starcat-pro` 构建依赖

全量测试与 `Starcat` Debug build 通过后，`StarcatDirect` Debug build 在 Copy Changelog 阶段失败：`supports/starcat-pro/CHANGELOG.md` 不存在。该目录被主仓库 `.gitignore` 排除，本机主目录中的 `supports/starcat-pro` 是独立 Git repository，因此新建 Starcat worktree 不会自动带入它。这是 worktree 构建环境缺口，不是本需求 Swift 编译错误。

修复要求：从本机现有 `starcat-pro` repository 的当前 `dev` commit 创建依赖 worktree 到任务 worktree的 `supports/starcat-pro`，不复制、不提交、不 push；随后重跑 `StarcatDirect` Debug build。

> 修复状态：已完成。以 `starcat-pro@6b1d8f2` 创建 detached 依赖 worktree；该目录保持主仓库 ignored，未进入提交。`StarcatDirect` Debug build 重跑通过。

## 工程门禁现状

- Wiki / RAG 六组定向测试：通过。
- `KnowledgeRAGCoreTests` + `RAGChunkRepositoryTests`：第二轮修复后通过。
- `Starcat` Debug build：通过。
- 全量 test：通过。
- `StarcatDirect` Debug build：首次因缺少本地 ignored 依赖失败，补齐 detached 依赖 worktree后重跑通过。
- `Localizable.xcstrings`：`jq empty` 通过。
- 分支工作区：clean；新增 Swift diff 无禁用 i18n 调用；逐次提交前 `git diff --check` 均通过。
- 已知非本需求 warning：`KnowledgeRAGCoreTests` 中既有 `@MainActor shouldOfferExternalSearchSettings` 测试诊断；不在本专项扩大修改。

## 本轮后续动作

1. [x] 补新入库与事件路由测试。
2. [x] 同步三处正式文档。
3. [x] 执行全量 test、双 target build 和最终静态检查。
4. [x] 回填本报告，进入第 4 轮无新增缺口复审。
