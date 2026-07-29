# 我的项目专项 Checklist

> 状态：已完成（真实 GitHub App 与 macOS 实机矩阵为外部验收 Gate）
>
> 创建：2026-07-29
>
> 基线：`dev@ec51a496`
>
> 分支：`codex/my-projects`
>
> Worktree：`/Users/dong4j/.codex/worktrees/my-projects/Starcat`
>
> 后续修订：已合并至主项目 `dev`，第 6 至第 12 轮在 `dev` 完成

## 1. 产品与权限边界

- [x] 固化整体落地方案和专项验收口径。
- [x] Sidebar 新增固定一级分类“我的项目”，并置于“全部仓库”之前。
- [x] 项目关系与 Star、知识库、Smart Collection 相互独立。
- [x] 首版范围限定为个人拥有仓库和组织成员仓库，不包含外部个人协作者仓库。
- [x] Public 项目可由现有 OAuth 提供 fallback。
- [x] Private / Internal 使用可选 GitHub App 只读授权（真实 Client ID 与组织审批为外部 Gate）。
- [x] 不把现有 OAuth 扩大为 `repo` scope。
- [x] 不在客户端保存 GitHub App private key 或 client secret。

## 2. 数据库与 Repository

- [x] 追加 `v17-my-projects`，不修改已发布 migration。
- [x] 新增 `user_projects` 表、约束和查询索引。
- [x] 新增 `project_sync_state` 表、约束和查询索引。
- [x] 新增 Project Record、领域模型和 GRDB Repository。
- [x] Project upsert 保留 Star、Tag、Note、Status、LibraryState、Pin 和洞察数据。
- [x] generation 全量成功后对账；分页失败保留旧关系。
- [x] 项目关系删除不删除 Repo 或用户内容。
- [x] 成功同步后幂等写入当天本机 Star snapshot。

## 3. 授权与同步

- [x] 新增独立 `ProjectAccessSession`，不复用 OAuth 登录状态。
- [x] GitHub App token 使用独立 Keychain account。
- [x] 实现 GitHub App Device Flow、token 刷新/过期/撤销状态。
- [x] 实现按用途选择 OAuth / GitHub App token 的凭据路由。
- [x] 实现 owner / organization_member 两条 `/user/repos` 分页链。
- [x] 实现 OAuth `visibility=public` fallback 和 GitHub App `visibility=all`。
- [x] 实现分页、Link Header、分 affiliation ETag、Rate Limit 和失败保旧值。
- [x] 实现后台有界同步和并发去重。
- [x] 实现首次连接、授权返回、启动刷新、后台刷新和手动刷新触发。

## 4. 查询与 UI

- [x] 新增 `.myProjects` Repo scope，禁止隐式要求 `is_starred = 1`。
- [x] Sidebar 显示真实项目计数。
- [x] 增加个人 / 组织 / 具体组织 / 可见性 / 权限筛选。
- [x] 项目筛选与搜索、语言、Tags、状态、Star、知识库筛选正确叠加。
- [x] 复用 Repo 行并展示项目归属、可见性、权限和本地 30 天增长。
- [x] 复用 Repo 详情、README、仓库洞察和 Star History。
  - 完成：owner / collaborator 按项目关系使用 OAuth 或 GitHub App 直连 GitHub Stargazers，并以“当前 Stargazers 重建”口径展示。
- [x] 非 GitHub Stargazers 来源显示访问限制说明和官方公告链接，并区分公共估算与本机快照。
- [x] Star History footer 使用稳定布局：不展示动态读数，图例靠左，日期范围与更新时间同排靠右；限制说明按需占第二行并保留 help / VoiceOver。
- [x] 未连接、连接中、部分授权、待审批、过期、撤销、失败和断网状态完整。
- [x] 刷新保留旧列表、当前 selection 和分页状态。
- [x] 完成 en / zh-Hans i18n 与辅助功能静态契约；VoiceOver、键盘和 Light / Dark 实机矩阵已明确为外部 Gate，未伪造人工结果。

## 5. Private 数据与缓存

- [x] Private / Internal 不调用 Discovery。
  - 完成：公共服务保持硬拦截；已授权项目仅直连 GitHub，并只保存按日聚合结果，不保存 Stargazer 身份。
- [x] Private / Internal 不进入 External Search、公开分享或 Universal Link。
- [x] 项目关系、同步状态和 Private 缓存不进入 CloudKit。
- [x] 默认 JSON 导出不包含项目关系、GitHub App token 或 Private 缓存。
- [x] 日志和错误落库不包含 Private owner/name、README 或响应 body。
- [x] Private README 使用 GitHub App token 和当前用户本地缓存。
- [x] 授权撤销后停止刷新并移除关系，但保留用户数据。
- [x] 提供本地 Private 远端缓存清理入口。

## 6. 测试与验收

- [x] v16 → v17 升级保留全部用户数据。
- [x] Repository 覆盖关系交叉、筛选、分页、generation 和删除语义。
- [x] API 覆盖 DTO、Link Header、304、401、403、Rate Limit 和中途失败。
- [x] Stargazers 覆盖 `star+json` 请求头、分页、OAuth / GitHub App 路由、按日累计和 Private 零 Discovery。
- [x] 授权覆盖 Device Flow、独立 session、token 过期/撤销和 OAuth 不受影响。
- [x] ViewModel 覆盖 scope、筛选隔离、计数、selection、刷新和并发代际。
- [x] 隐私测试证明 Private 项目不构造公共服务请求。
- [x] 运行专项单测、全量单测、Debug build和静态规范检查。
- [x] 人工权限矩阵步骤已固化；真实 Client ID、selected repositories 和组织审批验证明确为外部 Gate，未伪造执行证据。

## 7. 多轮审查

- [x] 第一轮：需求、方案、代码和 checklist 完整性审查；先写报告再修复。
- [x] 第二轮：数据库、授权、同步、隐私和失败语义审查；先写报告再修复。
- [x] 第三轮：UI、详情复用、i18n、VoiceOver 和交互审查；先写报告再修复。
- [x] 第四轮：单元测试、全量测试、Debug build和性能审查；先写报告再修复。
- [x] 第五轮：文档、工程进度、checklist 和 commit 历史一致性审查；先写报告再修复。
- [x] 第六轮：GitHub Stargazers 数据链与文档一致性审查；先写报告再修复。
- [x] 第七轮：Star History 代码、测试、文档和工程进度最终一致性复审。
- [x] 第八轮：Star History 不同来源折线连续性回归，补齐重建历史到本机快照的桥接段。
- [x] 第九轮：Sidebar 导航顺序与 Stargazers 访问限制说明的代码、测试、文档和进度一致性审查。
- [x] 第十轮：代码、单元测试、Debug build、官方依据、文档、checklist 和提交历史最终一致性复审。
- [x] 第十一轮：Star History footer 信息密度、响应式布局、i18n、辅助功能和自动化证据审查。
- [x] 第十二轮：Star History footer 底部稳定性、同排左右布局、图内选中态、i18n、测试与专项文档一致性审查。
- [x] 所有问题关闭后新增最终复审报告。
- [x] 多轮复审无新增问题后新增结果报告。

## 8. 提交约束

- [x] 从 `ec51a496` 创建独立 worktree 和 `codex/my-projects` 分支。
- [x] 每完成一个小功能使用中文 message commit。
- [x] 不 push。
- [x] 不带入主目录或当前 `dev` 的后续改动。
- [x] 最终专项 checklist 全部回填，工作区保持 clean。
