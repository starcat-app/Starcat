# checklist — API 聚合与 Kit 抽离专项

> 更新: 2026-08-07

## A. 上一轮架构沉淀

- [x] 架构调整文档 `01-架构调整-server导出与聚合.md`
- [x] 六个业务 API `server` 包导出（本地分支已有）
- [x] starcat-api-kit / starcat-api 本地仓
- [x] 版本策略写入 README（2.0.0 / sharing 2.1.0）
- [x] 各 API CHANGELOG 回填对应版本号
- [ ] 主仓 supports 登记文件提交（可选，随主仓策略）

## B. 本轮 Kit 抽离

- [x] 方案文档 `02-Kit继续抽离方案-GitHub-ping-env.md`
- [x] kit: `github` + RateLimitHandler + 单测（含 AllowAnonymous）
- [x] kit: `httputil` ping + 单测
- [x] kit: `env` + 单测
- [x] weekly / trending / sharing / discovery 接入 kit github
- [x] 六个 API ping 改用 kit
- [x] 相关 FromEnv 改用 kit/env（recommend / sharing；其余可继续渐进）

## C. Starcat 客户端

- [x] 审查 AppEndpoints / 各 *API actor 是否需改
- [x] 契约不变：文档 `03-Starcat客户端契约审查.md` + AppEndpoints v10 注释

## D. 质量闸门

- [x] 本地 go test / go build 相关包全绿
- [x] 不 push、不 Fly 部署
- [ ] 第 1 轮审查报告
- [ ] 第 2 轮审查报告（若第 1 轮有修复）
- [ ] 最终结果报告

## E. 功能实现总览

- [x] 拟写入文案已起草（见最终结果报告附录；审查收口后补齐）
- [ ] 等待 dong4j「可以写总览」后再改 `docs/功能实现总览.md`
