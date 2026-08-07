# API 聚合与 Kit 抽离专项

> 创建: 2026-08-07  
> 状态: **代码与文档收口中**（未授权不部署 / 不迁库 / 不 push）  
> 范围: `starcat-api-kit` / `starcat-api` / 六个业务 API（不含 license）/ Starcat 客户端  
> 约束: 铁律 #3（禁止擅自打包发布）；铁律 #4（总览需确认）

## 文档索引

| 文档 | 说明 |
|------|------|
| [01-架构调整-server导出与聚合.md](./01-架构调整-server导出与聚合.md) | server 导出、kit、网关、环境变量 Pin、**内存缓存** |
| [02-Kit继续抽离方案-GitHub-ping-env.md](./02-Kit继续抽离方案-GitHub-ping-env.md) | github / ping / env 抽离方案 |
| [03-Starcat客户端契约审查.md](./03-Starcat客户端契约审查.md) | B 方案：默认聚合 URL + `X-SC-Svc` |
| [04-聚合迁库SOP.md](./04-聚合迁库SOP.md) | 旧 App `/data` → `starcat-api`（人工执行） |
| [checklist.md](./checklist.md) | 任务 checklist |
| [第N轮审查报告.md](./第1轮审查报告.md) | 多轮审查 |
| [API聚合与Kit抽离专项完成结果报告.md](./API聚合与Kit抽离专项完成结果报告.md) | 结果报告 |

运维权威补充：`supports/docs/fly-io-环境变量.md`、`.claude/skills/starcat-supports-ops/references/ops-map.md`。

## 版本策略

六个业务 API 进入 **2.x 架构线**（可导出 `server` + 依赖 `starcat-api-kit`）：

| API | 本轮版本号 | 说明 |
|-----|------------|------|
| recommend / wiki / trending / weekly / discovery | **2.0.0** | 架构大版本 |
| sharing | **2.1.x** | 含 embed 等后续小版本 |
| starcat-api-kit | **0.2.0** | github / httputil / env |
| starcat-api | **0.1.x** | 聚合网关 |

## 总览登记

`docs/功能实现总览.md` 受铁律 #4 约束：**未获 dong4j「可以写总览」前不改写**。
