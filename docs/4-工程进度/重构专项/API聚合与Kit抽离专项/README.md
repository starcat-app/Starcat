# API 聚合与 Kit 抽离专项

> 创建: 2026-08-07  
> 状态: 进行中  
> 范围: `starcat-api-kit` / `starcat-api` / 六个业务 API（不含 license）/ Starcat 客户端对接检查  
> 约束: 仅本地验证；禁止 Fly 部署与生产变更；禁止 push

## 文档索引

| 文档 | 说明 |
|------|------|
| [01-架构调整-server导出与聚合.md](./01-架构调整-server导出与聚合.md) | 上一轮：server 包导出、kit 初建、聚合网关 |
| [02-Kit继续抽离方案-GitHub-ping-env.md](./02-Kit继续抽离方案-GitHub-ping-env.md) | 本轮：github / ping / env 抽离方案 |
| [03-Starcat客户端契约审查.md](./03-Starcat客户端契约审查.md) | 客户端是否需改：结论否 |
| [checklist.md](./checklist.md) | 任务 checklist |
| [第N轮审查报告.md](./第1轮审查报告.md) | 多轮审查 |
| [API聚合与Kit抽离专项完成结果报告.md](./API聚合与Kit抽离专项完成结果报告.md) | 最终报告（收口后写） |

## 版本策略

六个业务 API 进入 **2.x 架构线**（可导出 `server` + 依赖 `starcat-api-kit`）：

| API | 本轮版本号 | 说明 |
|-----|------------|------|
| recommend / wiki / trending / weekly / discovery | **2.0.0** | 此前未到 2.x，本轮定为架构大版本 |
| sharing | **2.1.0** | 已有 2.0.0/2.0.1，本轮记 2.1.0，语义同属 2.x 架构线 |
| starcat-api-kit | **0.2.0** | 新增 github / httputil / env |
| starcat-api | **0.1.0** | 聚合网关首个可本地运行版本 |

## 总览登记

`docs/功能实现总览.md` 受铁律 #4 约束：**未获 dong4j「可以写总览」前不改写**。拟写入文案见最终结果报告附录。
