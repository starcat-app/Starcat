# 全局搜索优化 Checklist

> 状态：验收问题已修复，待界面复验（2026-11-12，dong4j 授权开干）
> 工作区：`../Starcat-global-search-optimization`（分支 `codex/global-search-optimization`，基线 `dev@9639ada9`）
> 主关联：GitHub Issue #207 / Multica HOM-239
> 方案：同目录 [全局搜索优化方案.md](全局搜索优化方案.md)；产品决策见 §1.1
> 约定：每完成一个小功能勾选一项并本地提交一次；全部勾选后才向 dong4j 交付。

| 状态 | 编号 | 小功能 | 完成证据 / 提交主题 |
|---|---|---|---|
| [x] | C0 | 落盘 Checklist 与查询评测集 | `docs(search)` 提交；查询集含 Omarchy 回归样本与分类标注 |
| [x] | C1 | 语义查询与索引维护解耦 | `perf(search)` 提交；`search()` 不再补建 repo embeddings，缺索引与零命中可区分，定向单测通过 |
| [x] | C2 | 发现计划 / 证据 / 会话契约 | `refactor(search)` 提交；`SearchDiscoveryModels` 提供计划、证据、阶段、预算与轮次模型 |
| [x] | C3 | 搜索决策作用范围开关 | `feat(search)` 提交；`decisionSearchRoutingEnabled` 默认关闭，Labs 作用范围 UI，重置/键位齐全 |
| [x] | C4 | `SearchIntentRouter` 分流 | `feat(search)` 提交；确定性解析 + 双问题 noul + 搜索专属 Planner 降级，单测覆盖 |
| [x] | C5 | `RepositoryDiscoveryService` 编排 | `feat(search)` 提交；Planner、受控检索、可选候选提取、GitHub 核验、相关性重排、证据引用；定向单测通过 |
| [x] | C6 | Search Center 接入智能发现 | `feat(search)` 提交；`.all` 自动分流、基础搜索先行、15 秒预算、继续查找轮次、缓存与失败边界；定向单测通过 |
| [x] | C7 | Search Center 发现 UI | `feat(search)` 提交；阶段提示、智能查找、继续查找、匹配理由与证据入口 |
| [x] | C8 | 决策引擎 search_intent 归因 | `improve(ai)` 提交；operation 枚举与 TypeSafe/Laya 传输映射，用量归因区分 route/planning/extraction/ranking |
| [x] | C9 | 全语言本地化文案 | `improve(localization)` 提交；本次新增 key 覆盖当前全部支持语言，占位符与目录格式校验 |
| [x] | C10 | 定向与全量单测 | 路由/发现/预算/降级/开关联动测试全绿；`make test` 全量通过（452.356s，exit 0） |
| [x] | C11 | 双渠道标准构建 | App Store 通过（复核 39.93s；可执行 SHA-256 `5042e7ad…`）；Direct 通过（208.95s；build `202611121646`，可执行 SHA-256 `d5716310…`） |
| [x] | C12 | 交付收尾 | C0–C12 全部完成；分支基于 `9639ada9` 含 14 个提交；全量单测与双渠道构建通过；未 push / 合并 / 回写总览，未做真实联网与 GUI 验收 |
| [x] | C13 | 修复 Planner 响应字段解码 | 显式映射 snake_case 字段；实际 magpie 响应回放通过；39 项搜索定向测试通过；Direct Debug `202611122109` 构建并启动；`fix(search)` 提交 |

## 交付边界

- 每个勾选项的提交只包含该小功能本身，不改无关代码。
- 不回写 `docs/功能实现总览.md`（铁律 #4，需 dong4j 单独授权）。
- 不 push、不发布、不打包分发、不清理 worktree；合并回 `dev` 另行确认。
- 需要真实联网 / GUI 验收的样本（Omarchy 实搜、界面观感）在交付报告中单独列明验证路径。
