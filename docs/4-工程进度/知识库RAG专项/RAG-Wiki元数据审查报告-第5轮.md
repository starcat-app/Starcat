# RAG Wiki 元数据审查报告（第 5 轮）

> 审查日期：2026-07-17  
> 审查范围：最终需求逐项复核、代码/文档/测试/工程进度一致性、Git 收口  
> 审查结论：无新增功能缺口，无阻断问题，可以生成结果报告

## 最终需求复核

- [x] DeepWiki、ZRead、CodeWiki 只查询公开收录链接，不抓取正文，不新增 Wiki 分片。
- [x] 详情、搜索、Repo AI、Companion、后台补齐统一使用 `WikiContextService`；除该服务外无 Wiki 网络调用。
- [x] fresh / stale / miss、双 TTL、有界并发、pending/in-flight 去重、启动扫描、新入库、失败降级与切库 generation 屏障完整。
- [x] 私有仓库在消费、调度和服务边界阻断，不向第三方发送 identity。
- [x] Wiki 链接按固定顺序写入现有唯一 `metadata:0`；索引器只读缓存，save/reset 精确刷新 Metadata。
- [x] 最终命中仓库携带完整 Metadata；完整优先、compact fallback、Metadata 命中不重复、`structured_only` 保持 compact。
- [x] Evidence 全局两阶段装配，先保留所有可容纳仓库 Metadata，再加入普通分片；Metadata 不字符截断。
- [x] 不新增 `{metadataSection}`，不改变 RepoContext 独立 placeholder / budget。
- [x] Metadata 在 UI、ViewModel/domain、Repository 多层禁删，仍可查看、编辑；普通分片行为不变。
- [x] Metadata Wiki 链接只接受固定 provider + `http(s)`，使用系统浏览器打开；回答 Markdown 外链沿用现有路径。
- [x] 详情/搜索在 cache change/reset 后按当前 identity 原地回填或移除链接。

## 一致性复核

- 方案、详细设计、开发前问题清单、专项进度和实现一致。
- 第一至第四轮发现项均有“先报告、再修复、再回填”记录和独立中文提交。
- `docs/功能实现总览.md` 只读，未擅自修改；待确认同步草案放入最终结果报告。
- 本分支未包含数据库 migration、Wiki source、Metadata placeholder、独立 Debug stage 或新 citation 类型。
- `supports/starcat-pro` 仅作为 ignored 的本地 detached 依赖 worktree，用于验证 `StarcatDirect`，不属于任务 diff。

## 最终自动化证据

- Wiki / RAG 定向 suites：通过。
- 全量 `xcodebuild ... test`：通过。
- `Starcat` Debug build：通过。
- `StarcatDirect` Debug build：通过。
- `jq empty Starcat/Resources/Localizable.xcstrings`：通过。
- 新增 Swift diff 无禁用 i18n 调用；每个修改提交前 `git diff --check` 通过。
- 分支：`codex/rag-wiki-metadata`；工作区 clean；未 push。

## 保留的人工验收

自动化无法替代真实 UI 点击与真实外部 Wiki 网络观测。以下项目明确保留给 dong4j，不计为代码缺口，也不伪造完成：

- Metadata 行的 Wiki 按钮视觉、点击和系统浏览器跳转；
- 编辑 Metadata 后仍无删除入口，普通分片删除/恢复视觉未回归；
- 真实知识库冷缓存后台补齐后，详情、搜索和 Metadata 行的视觉更新；
- 私有仓库在真实网络日志中无 Wiki 出站。
