# 洞察中心性能优化 Checklist

> 状态：实施中（0 / 63 项完成）
>
> 开工日期：2026-07-29
>
> 基线：Starcat `c74133c`
>
> 范围：优化“我的洞察”和“仓库洞察”的缓存命中、网络请求数量、重复刷新、SQLite 解码与本地读取；保持现有 UI、动画、加载占位、数据口径和手动刷新语义。

## 1. 成功标准

- [ ] 缓存有效期内重复进入同一仓库洞察，GitHub 网络请求为 0。
- [ ] 同一 `account/database + repo + dataset + range` 的并发加载只执行 1 个底层请求。
- [ ] 同一仓库 10 秒内连续触发手动刷新只执行 1 轮。
- [ ] Activity 与 Recent Activity 的冷加载由 6 次 REST Search 收敛为最多 1 次 GraphQL 请求。
- [ ] 仓库洞察完整冷加载由最多 10 次 GitHub 请求降为最多 5 次，Star History 按现有独立覆盖策略计算。
- [ ] ETag 命中 304 时保留 payload，只续期缓存，不重复 JSON 解码。
- [ ] stale 刷新失败保留最后成功内容；退避期内不重复请求。
- [ ] A → B → A 返回仓库时命中有界热点缓存，不重复读取和解码同一 payload。
- [ ] 账户 / 数据库切换硬清空热点缓存、冷却与 in-flight，禁止跨账户复用。
- [ ] 页面不新增中央加载环，不清空刷新中的可见内容，不改变现有动画。

## 2. 基线审计

- [ ] 记录当前冷加载请求构成：Activity 4、Recent Activity 2、Commit 1、Contributors 1、Community 1、Security 1。
- [ ] 确认 `repo_insights_snapshots.response_etag` 已落库但未贯通 `If-None-Match`。
- [ ] 确认 README 已有 6 小时 SWR、ETag 和 in-flight 去重，不重复改造。
- [ ] 确认 My Insights 已有 revision + 60 秒缓存，不新增 summary 表或后台任务。
- [ ] 确认 Repo List 已有 account-scoped prepared snapshot / LRU，不重复建立第二套列表缓存。
- [ ] 记录现有测试、构建和工作区基线。

## 3. 请求协调

- [ ] 新增账户隔离的洞察请求 Key，完整包含 repo、dataset、range 和认证代次。
- [ ] 同 Key in-flight 请求合并；任一调用方取消不能错误取消其他等待者。
- [ ] 手动刷新增加完成后 10 秒冷却，刷新期间继续保留旧内容。
- [ ] 403 / 429 严格尊重 `Retry-After` / `X-RateLimit-Reset`。
- [ ] 普通失败使用有界指数退避；401 不缓存，认证变化立即解除。
- [ ] 为请求合并、冷却、退避和账户切换补单元测试。

## 4. ETag 与 304

- [ ] Commit、Contributors、Community、Security 接受并发送 `If-None-Match`。
- [ ] Provider 从 SQLite 缓存读取 ETag，不由 View 自行保存。
- [ ] Cache 增加 304 touch 能力，只更新 `fetched_at / stale_after / response_etag`。
- [ ] 304 且本地 payload 丢失时无条件重拉一次，避免空缓存被误判为有效。
- [ ] 为 200、304、缓存丢失、ETag 更新和旧 payload 保留补测试。

## 5. Activity Bundle

- [ ] 使用类型化 GraphQL aliases 一次查询 4 个活动计数与最近 PR / Issue。
- [ ] 复用现有 GitHub Token、统一 401 和 Rate Limit 处理，不新增第二套认证链。
- [ ] Activity 与 Recent Activity 从同一成功响应派生并分别写入现有缓存。
- [ ] GraphQL 不可用时回退现有 REST Search，并保持同一缓存契约。
- [ ] 为请求数、字段映射、fallback、范围日期和失败保旧值补测试。

## 6. 热点缓存与本地读取

- [ ] 在 GRDB 洞察缓存上增加有界 decoded-value LRU，容量和内存预算固定。
- [ ] `store/remove/corruption/account switch` 精确失效热点条目。
- [ ] 热点 Key 包含账户 / 数据库身份，禁止跨库命中。
- [ ] 合并 Release、Release cadence、Health、OpenSSF、Community 的本地读取。
- [ ] 本地 Snapshot 使用一致 read transaction；写入后按数据源精确失效。
- [ ] 为 A → B → A、LRU 淘汰、精确失效和本地一致读取补测试。

## 7. TTL 与非目标

- [ ] Activity / Recent 保持 15 分钟；Commit / Contributors 保持 24 小时。
- [ ] Community 调整为 3 天；Security 调整为 6 小时。
- [ ] 404 / 422 negative cache 24 小时；403 只在当前认证代次短期缓存；401 不缓存。
- [ ] Star History 保持现有覆盖判断、24 小时远端策略和有限 202 轮询。
- [ ] 不批量预取全部收藏仓库，不为缓存命中增加 UI 提示或新动画。
- [ ] 第一轮不新增 migration；如需持久化失败退避，另行设计追加迁移并征求确认。

## 8. 验证与审查

- [ ] 建立 warm / stale / miss / 304 / concurrent / account-switch 请求计数测试。
- [ ] 运行相关定向 Suite、`build-for-testing`、String Catalog 与 `git diff --check`。
- [ ] 新增性能优化设计回填与请求数前后对比。
- [ ] 至少进行两轮代码、测试、文档、Checklist 和提交一致性审查。
- [ ] 每轮先新增审查报告，再修复发现的问题。
- [ ] 连续两轮无新增 P0 / P1 / P2 后新增结果报告。
- [ ] `docs/功能实现总览.md` 未获得单独授权，保持只读不写。

## 9. 计划提交

- [ ] `docs(insights): 建立洞察性能优化清单`
- [ ] `perf(insights): 合并重复仓库洞察请求`
- [ ] `perf(insights): 启用洞察 ETag 条件刷新`
- [ ] `perf(insights): 合并活动与最近动态查询`
- [ ] `perf(insights): 增加洞察热点快照缓存`
- [ ] `perf(insights): 合并仓库本地洞察读取`
- [ ] 每项功能对应独立 `test(insights)` 提交。
- [ ] 文档、审查报告、修复和结果报告分别提交。

## 10. 人工验收边界

- [ ] dong4j 验收 README / 洞察反复切换无跳动、无重复加载感。
- [ ] dong4j 验收 A → B → A 仓库切换返回速度。
- [ ] dong4j 使用真实账户确认 Rate Limit、离线、403 / 429 和旧缓存状态。
- [ ] 如需精确 p50 / p95，使用 Instruments 固定短时脚本人工采样。

自动化不得伪造主窗口体感、真实 GitHub 配额或 Instruments 结论；未观察项保持未勾选。
