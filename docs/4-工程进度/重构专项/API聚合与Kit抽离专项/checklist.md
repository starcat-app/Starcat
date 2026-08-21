# checklist — API 聚合与 Kit 抽离专项

> 更新: 2026-08-08

## A. 上一轮架构沉淀

- [x] 架构调整文档 `01-架构调整-server导出与聚合.md`
- [x] 六个业务 API `server` 包导出（本地分支已有）
- [x] starcat-api-kit / starcat-api 本地仓
- [x] 版本策略写入 README（2.0.0 / sharing 2.1.x）
- [x] 各 API CHANGELOG 回填对应版本号
- [ ] 主仓 supports 登记文件提交（可选，随主仓策略）

## B. 本轮 Kit 抽离

- [x] 方案文档 `02-Kit继续抽离方案-GitHub-ping-env.md`
- [x] kit: `github` + RateLimitHandler + 单测（含 AllowAnonymous）
- [x] kit: `httputil` ping + 单测
- [x] kit: `env` + 单测
- [x] weekly / trending / sharing / discovery 接入 kit github
- [x] 六个 API ping 改用 kit
- [x] 相关 FromEnv 改用 kit/env（六业务 API 均已接入）

## C. Starcat 客户端

- [x] 审查 AppEndpoints / 各 *API actor 是否需改
- [x] B 方案契约：默认聚合 URL + `X-SC-Svc`
- [x] 六服务 productionURL / 分流头回归测试

## D. 第 3 轮加固

- [x] Fly 构建上下文改为 `supports/`，新增白名单 `.dockerignore`
- [x] 服务 env 改为 `Apply → FromEnv → restore`，仅显式 Pin wiki 四个运行期 key
- [x] Discovery Admin Key 改为 secrets 同步硬必填
- [x] Weekly Wiki notifier 补 `X-SC-Svc: wiki` 与测试
- [x] 聚合维护模式：业务不挂载、`/healthz` 报 maintenance、其它 503
- [x] 五份备份离线合并、完整性检查和聚合整包恢复工具
- [x] Sharing 公网路由与 Starcat 正式发布门禁写入迁库 SOP
- [x] 第 4 轮同步目标架构、当前线上状态、恢复破坏范围和客户端 healthz 语义
- [x] `starcat-api` / `starcat-weekly-api` 的 `Unreleased` Changelog 登记当前加固

## E. 质量闸门

- [x] 本地 go test / go build 相关包全绿
- [x] 未 push；Fly 部署仅在 dong4j 明确授权后执行
- [x] 第 1 轮审查报告
- [x] 第 2 轮审查报告
- [x] 第 3 轮审查报告
- [x] 第 4 轮文档一致性审查报告
- [x] 本地静态 / 单元 / 构建验证
- [x] Docker build check（OrbStack；Check complete, no warnings found）
- [x] Fly 聚合维护模式部署与首轮五库种子迁移（人工，2026-08-08）
- [ ] 切流前最终同步 / 写入冻结窗口（人工）
- [x] 解除维护模式并完成六服务 ping / 只读业务验证（人工，仅本地 / 受控双跑，不代表最终切流）
- [x] 验证后重新开启维护模式、关闭 Machine 自动唤醒并停止 `starcat-api`（人工，2026-08-08；App / Volume / Secrets / Snapshot 保留）
- [ ] 最终同步后的六服务生产复验（人工）
- [x] 聚合 `.env` 已生成独立 `DISCOVERY_ADMIN_API_KEYS`，格式/唯一性/权限/Git 忽略校验通过
- [x] 人工执行 Fly secrets 同步（2026-08-08，未记录明文）
- [x] 创建 `starcat-api` App 与 nrt Volume，并以维护模式完成首次部署；当前六个独立 App 继续承载生产
- [ ] `starcat.ink` Sharing 公开路由验收（人工）
- [x] 1.4.0 appcast 与 App Store 更新说明加入老版本在线能力下线提示
- [ ] 确认 Direct / App Store 1.4.0 均可下载后，六个旧 App Machine 直接停机
- [ ] 旧 App 稳定观察与最终销毁（保留期结束后人工二次确认）

## F. 功能实现总览

- [x] `docs/功能实现总览.md` 已登记 R-10；其部署状态需另获明确授权后同步，本轮未改写
- [x] 本轮一致性同步未改写 `docs/功能实现总览.md`
