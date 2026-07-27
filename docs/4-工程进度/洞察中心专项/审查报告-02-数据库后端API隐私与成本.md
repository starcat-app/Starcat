# 审查报告 02：数据库、后端、API、隐私与成本

> 审查时间：2026-07-27
>
> 审查状态：已完成专项检查，存在 1 个待修复 finding
>
> 审查基线：Starcat `20f00d0d`；`starcat-discovery-api` `0a107d2`

## 1. 审查范围

- Starcat `v16-repository-insights` 追加迁移、外键、约束、TTL、损坏缓存和既有用户升级。
- Star History 客户端缓存、私有仓库拦截、CloudKit 与 JSON 导入导出边界。
- Discovery 缓存表、Provider、归一化、降采样、worker、公开性复核和 HTTP contract。
- BigQuery 单次 / 每日预算、日志、token 和部署默认值。

## 2. 结论

v16 迁移、客户端隐私边界、Discovery 公开性复核、API 状态和单次 BigQuery 扫描上限均符合方案。发现 1 个 P1 成本护栏问题：每日预算只保存在 Service 进程内存，服务重启会归零，因此配置名所承诺的“每日预算”不是跨重启硬上限。

M0 仍未取得真实 BigQuery 查询授权，`STAR_HISTORY_ENABLED` 必须继续保持默认 `false`；本报告不把 Fake / dry-run 测试写成 M0 GO。

## 3. Findings

### R02-F01：Star History 每日扫描预算可被服务重启重置

- 等级：P1
- 状态：待修复
- 证据：
  - `internal/starhistory/service.go` 使用 `budgetDay / budgetUsed` 内存字段和 `reserveDailyBudget(...)`。
  - `NewService(...)` 每次启动都把预算使用量恢复为 0。
  - 代码注释明确承认“服务重启最多丢失内存计数”，但这会让 `STAR_HISTORY_DAILY_MAX_BYTES_BILLED` 在同一 UTC 日内被多次重新消费。
- 风险：部署重启、崩溃恢复或滚动更新后，当日累计扫描上限可能超过配置值；BigQuery `maximumBytesBilled` 只能限制单次查询，不能替代每日总预算。
- 修复要求：
  1. 在 Discovery SQLite 增加独立的 UTC 日预算表。
  2. 通过原子 SQL 在任务开始前持久化预留 `MaximumBytesBilled`；超过当日上限时拒绝。
  3. Service 依赖持久化 Store 方法，删除进程内计数。
  4. 增加并发预留、跨 Service 重建、跨日重置和超限测试。
  5. 运行 `make check && go build ./...`。
- 修复 commit：待回填
- 验证结果：待回填

## 4. 无问题项

- Starcat 只追加 `v16-repository-insights`，未改写已发布 migration。
- 两张客户端缓存表均通过 `repo_id` 外键级联清理，Star 数量有非负约束。
- 损坏活动 payload 只删除对应 dataset / range，不影响其他缓存或用户数据。
- 两张缓存表未进入 CloudKit、JSON 导入导出或用户数据模型。
- 私有仓库在 Repository 与 API 两层均在构造公共请求前拦截。
- Discovery cache 以 repo ID 为主键，并用缓存 `full_name` 或 GitHub metadata 复核 owner/name。
- 成功、building、failed 均有 TTL；过期 building 可重新认领。
- Provider 使用命名参数、强制 dry run 和正数 `maximumBytesBilled`。
- handler 已覆盖 `200 / 202 / 304 / 400 / 401 / 404 / 409 / 422 / 429 / 503`。
- API Key / GitHub token 不进入 Star History 响应或错误缓存；认证日志只输出掩码。
- `STAR_HISTORY_ENABLED` 默认关闭，文档明确 M0 与部署必须另行授权。

## 5. 下一步

本报告提交后，按 R02-F01 在 `starcat-discovery-api` 独立修复、验证并提交；随后回填本报告并继续第三轮架构与失败路径审查。
