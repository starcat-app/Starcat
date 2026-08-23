# Awesome 发现专项实施 Checklist

> 状态：功能开发完成，审查中  
> 日期：2026-08-24  
> 需求与技术契约：[`Awesome发现栏目与来源管理正式方案.md`](../../2-产品/需求讨论/正式方案/Awesome发现栏目与来源管理正式方案.md)  
> Issue：[#109](https://github.com/starcat-app/Starcat/issues/109)  
> 分支：主仓库及两个配套仓库均为 `codex/awesome-discovery`

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
- [x] 来源卡片展示图片回退、名称、介绍、仓库、项目数、推荐和勾选状态。
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

- [ ] 第 1 轮完成文档、代码、测试、工程进度审查，报告已保存，发现项已修复并提交。
- [ ] 第 2 轮完成文档、代码、测试、工程进度审查，报告已保存，发现项已修复并提交。
- [ ] 第 3 轮完成文档、代码、测试、工程进度审查，报告已保存，无遗留技术问题。
- [ ] 生成《Awesome 发现需求完成结果报告.md》。
- [ ] 将 Issue #109 推进到待人工验收；未经 dong4j 验收不关闭 Issue。

## 8. 全局总览同步边界

- [x] 已只读检查 `docs/功能实现总览.md`。
- [ ] 技术实现完成后起草总览条目、`> 实现：` 和变更日志候选文本。
- [ ] 仅在 dong4j 明确说“同步总览 / 可以写总览 / 记到总览 / 勾上”后修改 `docs/功能实现总览.md`。
