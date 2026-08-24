# Awesome 发现专项实施 Checklist

> 状态：来源添加、真实描述、搜索、卡片视觉和详情元数据验收修复已完成；Discovery API 代码待重新部署，客户端待人工 UI 验收
> 日期：2026-08-24  
> 需求与技术契约：[`Awesome发现栏目与来源管理正式方案.md`](../../2-产品/需求讨论/正式方案/Awesome发现栏目与来源管理正式方案.md)  
> Issue：[#109](https://github.com/starcat-app/Starcat/issues/109)  
> 分支：原专项分支已合入；本轮按 dong4j 要求直接在三个仓库本地 `dev` 修复

## 1. 开工与工程隔离

- [x] 主仓库基于本地 `dev@60b16b8f` 建立独立 worktree。
- [x] `starcat-discovery-api` 基于本地 `dev@5f0be016` 建立独立 worktree。
- [x] `starcat-site` 基于本地 `dev@71126ee` 建立独立 worktree。
- [x] 核对正式方案、开发前决议、全局工程总览和 UI 强制规范。
- [x] 将 Issue #109 与 GitHub Project 推进到开发中。

## 2. Discovery API

- [x] 追加 `awesome_sources`、`awesome_entries`、`awesome_sync_runs` 表及索引，保证现有 volume 原地升级。
- [x] 实现来源 Store、字段校验、revision 乐观并发和状态机。
- [x] 实现 CommonMark/GFM AST README 解析、GitHub URL 归一化和解析限制。
- [x] 实现 GitHub 来源核验、Repo enrich、同步事务、失败保留旧快照和 active run 幂等。
- [x] 实现精选来源目录和单来源 entries 公共 API，包含 ETag、304、排序与缓存失效。
- [x] 实现来源 CRUD、同步、发布、下架和 sync-runs Admin API，并隔离鉴权。
- [x] 补齐 API 中英文文档、单元测试并通过 `go test ./...`、`go vet ./...`。

## 3. 本地运营后台

- [x] 增加 Awesome 来源列表、状态、计数、同步结果和错误展示。
- [x] 增加来源新增、编辑、稳定排序以及 revision 冲突处理。
- [x] 增加同步、发布、下架确认和 sync run 状态恢复。
- [x] 验证 Awesome Admin key 只由本地受限代理注入且不进入表单/日志；Node 测试与整页脚本语法检查通过。

## 4. Starcat 数据层

- [x] 追加 `v22-awesome-discovery` migration，不修改 `v1-initial`。
- [x] 增加 Awesome DTO、公共 API、ETag/304 和错误 envelope 解码。
- [x] 增加账户隔离的来源目录、订阅、条目和首次配置状态缓存。
- [x] 增加精选来源 SWR 刷新、单来源事务替换、失败保留旧条目和下架降级。
- [x] 增加自定义来源输入归一化、公开 Repo/README 核验、本地 AST 解析和删除语义。
- [x] 实现“全部 Awesome”按 `gh_repo_id` 去重、稳定排序和多来源证据聚合。

## 5. Starcat 界面

- [x] Awesome 位于探索的周刊下方，未新增一级主栏目。
- [x] 周刊显示语言列表；Awesome 显示全部及已启用来源，切换状态互不串扰。
- [x] Awesome 名称右侧提供独立管理按钮，且不会误触整行选择。
- [x] 首次点击自动打开卡片式来源 Sheet；取消不完成，完成零选择也不再自动弹出。
- [x] 来源卡片展示图片回退、名称、介绍、仓库、来源 Stars、项目数、同步状态、推荐和勾选状态。
- [x] 支持添加、停用和删除本地自定义来源，且不上传 Discovery。
- [x] 中栏支持全部/单来源、章节、搜索与排序；外部链接不进入 Repo 列表。
- [x] 右栏复用现有 Repo 详情并展示当前来源、其他来源和安全的原始 README 链接。
- [x] 接入 i18n、Accessibility、键盘焦点以及 loading/error/empty/stale/unavailable 状态。

## 6. 测试与一致性

- [x] Discovery API 自动化测试覆盖正式方案 §14.1。
- [x] Starcat 自动化测试覆盖正式方案 §14.2。
- [x] `_local-admin` 验证覆盖正式方案 §14.3。
- [x] `xcodegen generate` 后定向测试和完整 `xcodebuild test` 通过。
- [x] 现有发现、趋势、热门、新发布、周刊和 Manage 三栏无自动化回归。
- [x] 人工 UI 验收项已明确记录；未执行的人工门禁不得写成已通过。

## 7. 多轮审查与收口

- [x] 第 1 轮完成文档、代码、测试、工程进度审查，报告已保存，发现项已修复并提交。
- [x] 第 2 轮完成文档、代码、测试、工程进度审查，报告已保存，发现项已修复并提交。
- [x] 第 3 轮完成文档、代码、测试、工程进度审查，报告已保存，无遗留技术问题。
- [x] 第 4 轮完成验收问题、生产状态与文档审查，发现项已修复并提交。
- [x] 第 5 轮完成生产 live、最终差异与进度文档审查，发现项已修复并提交。
- [x] 第 6 轮完成最终一致性审查，发现的活文档测试数字偏差已修复并提交。
- [x] 第 7 轮完成文档、代码、测试、工程进度和生产健康终审，无新增技术遗留问题。
- [x] 生成《Awesome 发现需求完成结果报告.md》。
- [x] 将 Issue #109 推进到待人工验收；未经 dong4j 验收不关闭 Issue。

## 8. 全局总览同步边界

- [x] 已只读检查 `docs/功能实现总览.md`。
- [x] 已在最终结果报告中起草总览条目、`> 实现：` 和变更日志候选文本。
- [x] 本任务未获得“同步总览”单独授权，已保持 `docs/功能实现总览.md` 不变；后续只在 dong4j 明确授权后写入。

## 9. 验收问题修复（2026-08-24）

- [x] 修复 entries 响应省略 `is_archived=false` 导致客户端整批解码失败的问题，并增加服务端契约测试与客户端降级解码。
- [x] 每轮来源同步刷新来源仓库自身 GitHub 元数据，目录 API 增加 `source_stars`，不在 `awesome_sources` 重复保存 Stars。
- [x] 客户端追加 `v23-awesome-source-metadata` 迁移，缓存来源 Stars 与最近同步时间，现有本机库无需重建。
- [x] 来源卡片增加 Stars、解析项目数、最近同步/失败状态，并优化头像、层级、间距、选中态和明暗主题语义色。
- [x] 来源选择改为同步更新高亮、取消旧加载并校验返回代际；快速切换回归测试通过。
- [x] Discovery API `81` 条测试与 `go vet` 通过；Starcat Awesome/API/Repository/Migration/Store 定向测试与 macOS build 通过。
- [x] 完成本轮第 6/7 轮最终一致性审查，并保存独立审查报告。
- [x] 更新最终结果报告并交付 dong4j 人工 UI 复验。

## 10. 双层缓存补强（2026-08-24）

- [x] 客户端追加 `v24-awesome-cache-freshness`，独立记录目录与每个来源条目的最近有效检查时间。
- [x] 客户端自动加载采用 6 小时 freshness，缓存新鲜时不请求远端；缺少缓存、缓存过期或新订阅来源才发起刷新。
- [x] 客户端手动刷新绕过 freshness 并携带 ETag；`304` 推进检查时间，失败继续展示旧快照。
- [x] Discovery API 在 SQLite 持久快照之上增加 JSON/gzip/ETag 响应缓存，使用 64 条 / 64 MiB 有界 LRU。
- [x] Discovery API 合并同 key 并发 miss，并在 CRUD、同步、发布、下架后精确失效，防止旧的在途构建回填。
- [x] Starcat 全量测试 `2652` total、`2641` passed、`0` failed；Discovery API `85` 条测试、race 定向 `35` 条测试与 `go vet` 通过。
- [x] 聚合 `starcat-api` `11` 条测试与 `go vet` 通过，直接复用本地 Discovery module。
- [x] 完成本轮第 8 至第 10 轮审查并保存独立审查报告。
- [x] 更新最终结果报告并将 Issue #109 重新推进到人工验收。

## 11. 完整仓库元数据与三列来源 UI（2026-08-24）

- [x] 来源目录 `source_stars` 改为必返强契约；客户端追加 `v25-awesome-source-stars-refresh`，历史零值目录立即失效重拉。
- [x] Discovery entries 补齐 forks、watchers、subscribers、open issues、主页、默认分支、license、topics、fork/archive 与创建/推送/更新时间。
- [x] 服务端增加 `repo_metadata_version`，历史来源只强制重新 enrich 一次，成功后继续按 README SHA 命中缓存。
- [x] 客户端追加 `v26-awesome-repository-metadata`，完整事实进入账户 SQLite、Awesome 聚合模型和统一详情 Hero。
- [x] 自定义来源继续只调用 GitHub API 并写当前账户本地库，不上传 Discovery；本地映射 forks、watchers、topics 和时间等事实。
- [x] 来源 Sheet 固定三列，卡片使用 Repo 风格胶囊、稳定高度、整卡点击、hover/选中态和真实来源 Logo。
- [x] 侧边栏来源行复用内容管理图片或 GitHub owner avatar；输入区标题改为“新增 Awesome 项目”。
- [x] Starcat 全量测试、Discovery API 全量/race/vet、聚合 API 测试与三仓静态门禁通过。
- [x] 第 11 至第 13 轮审查报告全部保存，发现项全部修复并提交。
- [x] 最终结果报告、人工 UI 清单和 Issue #109 状态与最终实现一致。

## 12. 生产部署与数据回填（2026-08-24）

- [x] 部署前创建 `starcat-api` 生产 Volume 快照，保留 SQLite 回滚点。
- [x] 从 `supports/` 构建上下文部署聚合 `starcat-api`，确保正式客户端实际使用的 Discovery 分流包含本轮源码。
- [x] Fly Release v10 完成，Machine、`/healthz` 和六个服务 `/api/v1/ping` 全部健康。
- [x] 手动刷新 `awesome-mac`、`awesome-design-patterns` 和 `awesome-python`，分别写入 285、29、475 条完整 Repo 元数据。
- [x] 三个来源的 Stars、forks、watchers、subscribers、open issues、默认分支和创建/推送/更新时间缺失数均为 0。
- [x] 其余 published 来源继续由每 3 小时定时任务按 README SHA 增量刷新；旧快照在回填期间保持可读。
- [x] 保存第 14 轮生产部署审查报告并更新 Issue #109；Issue 保持 Open/`Acceptance` 等待人工 UI 验收。

## 13. 来源管理与详情验收修复（2026-08-24）

- [x] 自定义来源点击“添加”后立即保存并启用；失败在输入区显示明确错误，不再依赖二次确认弹窗。
- [x] Discovery 来源目录新增 `repo_description`，从共享 `repos` 真值读取来源仓库 GitHub 官方描述。
- [x] 客户端追加 `v28-awesome-source-description`，缓存 `repo_description` 并主动清除旧目录 ETag 触发刷新。
- [x] 来源 Sheet 增加左上角 Awesome 图标、持久搜索框和搜索无结果空态；搜索覆盖名称、仓库、官方描述和内容摘要。
- [x] 来源卡片优先显示 GitHub 官方描述，增加 GitHub 跳转按钮、Logo 采样渐变、元数据胶囊和稳定三列布局。
- [x] Discovery 详情改为当前 entries 公共元数据优先，避免本地旧 starred 缓存遮蔽 watchers、subscribers 和创建/更新时间。
- [x] `RepoDetailHero(repo:)` 透传 `subscribersCount`，并增加订阅数与时间字段回归测试。
- [x] Starcat 全量 `2665` 项测试通过（`0` failed）；最终低风险 UI 修复后 Awesome 定向测试再次通过。
- [x] Discovery API `86` 项测试与 `go vet` 通过；正式方案、专项结果报告和人工 UI 清单已同步。
- [x] 完成第 15、16 轮审查，发现项全部修复并保存独立报告；`docs/功能实现总览.md` 未获单独授权，保持不变。
