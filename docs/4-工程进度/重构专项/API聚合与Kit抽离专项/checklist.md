# checklist — API 聚合与 Kit 抽离专项

> 更新: 2026-08-07

## A. 上一轮架构沉淀

- [x] 架构调整文档 `01-架构调整-server导出与聚合.md`
- [x] 六个业务 API `server` 包导出（本地分支已有）
- [x] starcat-api-kit / starcat-api 本地仓
- [x] 版本策略写入 README（2.0.0 / sharing 2.1.0）
- [ ] 各 API CHANGELOG 回填对应版本号
- [ ] 主仓 supports 登记文件提交（可选，随主仓策略）

## B. 本轮 Kit 抽离

- [ ] 方案文档 `02-Kit继续抽离方案-GitHub-ping-env.md`（本文档已写）
- [ ] kit: `github` + RateLimitHandler + 单测
- [ ] kit: `httputil` ping + 单测
- [ ] kit: `env` + 单测
- [ ] weekly / trending / sharing / discovery 接入 kit github
- [ ] 六个 API ping 改用 kit
- [ ] 相关 FromEnv 改用 kit/env（可渐进）

## C. Starcat 客户端

- [ ] 审查 AppEndpoints / 各 *API actor 是否需改
- [ ] 若契约不变：文档说明；若需改：最小 diff

## D. 质量闸门

- [ ] 本地 go test / go build 全绿（相关仓）
- [ ] 不 push、不 Fly 部署
- [ ] 第 1 轮审查报告
- [ ] 第 2 轮审查报告（若第 1 轮有修复）
- [ ] 最终结果报告

## E. 功能实现总览

- [ ] 拟写入文案已起草
- [ ] 等待 dong4j「可以写总览」后再改 `docs/功能实现总览.md`
