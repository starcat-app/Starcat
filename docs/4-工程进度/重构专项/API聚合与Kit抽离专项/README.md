# API 聚合与 Kit 抽离专项

> 创建: 2026-08-07  
> 状态: **首轮五库种子迁移与功能验证完成；聚合已停机保留，待 1.4.0 最终同步 / 生产切流**（旧 App 保持运行）
> 范围: `starcat-api-kit` / `starcat-api` / 六个业务 API（不含 license）/ Starcat 客户端  
> 约束: 铁律 #3（禁止擅自打包发布）；铁律 #4（总览需确认）

## 文档索引

| 文档 | 说明 |
|------|------|
| [01-架构调整-server导出与聚合.md](./01-架构调整-server导出与聚合.md) | server 导出、kit、网关、环境变量隔离、**内存缓存** |
| [02-Kit继续抽离方案-GitHub-ping-env.md](./02-Kit继续抽离方案-GitHub-ping-env.md) | github / ping / env 抽离方案 |
| [03-Starcat客户端契约审查.md](./03-Starcat客户端契约审查.md) | B 方案：默认聚合 URL + `X-SC-Svc` |
| [04-聚合迁库SOP.md](./04-聚合迁库SOP.md) | 旧 App `/data` → `starcat-api`（人工执行） |
| [checklist.md](./checklist.md) | 任务 checklist |
| [第1轮审查报告.md](./第1轮审查报告.md) / [第2轮审查报告.md](./第2轮审查报告.md) | 初始实现审查（历史快照） |
| [第3轮审查报告.md](./第3轮审查报告.md) | 部署、环境隔离、迁库与公网契约复审 |
| [第4轮文档一致性审查报告.md](./第4轮文档一致性审查报告.md) | 当前实现、线上状态、运维边界与代码注释一致性复审 |
| [API聚合与Kit抽离专项完成结果报告.md](./API聚合与Kit抽离专项完成结果报告.md) | 结果报告 |

运维权威补充：`supports/docs/fly-io-环境变量.md`、`.claude/skills/starcat-supports-ops/references/ops-map.md`。

## 当前边界

- 客户端维持聚合 production URL；聚合已完成本地 / 受控验证。1.4.0 正式发布前必须在写入冻结窗口完成最终同步，再解除维护并完成生产复验。
- 本地已补齐安全构建上下文、服务 env 隔离、维护模式、五库离线合并恢复工具和契约测试。
- 本地最终闸门已通过：聚合 Docker build check 无 warning，`starcat-api` / Weekly 全量 Go 测试和 Starcat 客户端契约定向测试通过；两个组件 `Unreleased` 已登记。
- 2026-08-08 已完成 Fly App / Volume / Secrets / 维护模式首次部署与首轮五库种子迁移；远端五库 SHA-256 与合并归档逐一一致，`weekly-repo` 本地/远端均为 545 个文件，迁后 Snapshot `vs_P2NQQAXpbv9jUyVVmvy5qe5v` 已创建。
- 旧 Wiki `wiki.db` 在备份后继续更新（当前 mtime `2026-08-08 13:14:05 UTC`），证明本轮是可恢复性与迁库流程验证成功的种子批次，不是零漂移最终切流快照。
- 维护模式解除后，聚合 `/healthz` 为 `status=ok`；六服务鉴权 ping 全部 200，Trending / Weekly 列表、Wiki probe、Recommend 查询、Discovery summary、Sharing stats 与公网页只读抽样全部 200。聚合 `wiki.db` 已产生新写入，证明 `app:app` 权限修复有效。
- 2026-08-08 验证通过后已重新设置 `STARCAT_MAINTENANCE_MODE=true`，Machine `185de96f791908` 已停止并设置 `autostart=false`；App、Secrets、Volume `vol_458j3e5ky32ln1q4` 保留，六个旧 App 继续承载生产。Snapshot `vs_P2NQQAXpbv9jUyVVmvy5qe5v` 当前状态正常但平台保留期仅 5 天，不能替代 1.4.0 切流前的新备份。
- 聚合 `.env` 的 `DISCOVERY_ADMIN_API_KEYS` 已本地生成并通过格式/唯一性校验，且已随聚合 Secrets 同步到 Fly；明文未写入文档或日志。
- 1.4.0 发布门禁固定为：冻结旧服务写入 → 最终同步 → 聚合复验 → `starcat.ink` 代理切换 → 确认 Direct / App Store 1.4.0 可下载 → 旧 App Machine 直接停机。旧 App / Volume 先保留作回滚资产，不立即销毁。
- 老版本无需新增客户端双轨：Direct 依赖现有 Sparkle，App Store 版依赖现有 24 小时自动检查。1.4.0 的 appcast 与 App Store 更新说明必须明确提示：旧版本仍可查看本地缓存，但在线刷新、推荐、发现、Wiki 和分享等服务将不可用，请尽快更新。

## 版本策略

六个业务 API 进入 **2.x 架构线**（可导出 `server` + 依赖 `starcat-api-kit`）：

| API | 本轮版本号 | 说明 |
|-----|------------|------|
| recommend / wiki / trending / weekly / discovery | **2.0.0** | 架构大版本 |
| sharing | **2.1.x** | 含 embed 等后续小版本 |
| starcat-api-kit | **0.2.0** | github / httputil / env |
| starcat-api | **0.1.x** | 聚合网关 |

## 总览登记

`docs/功能实现总览.md` 已登记 R-10；根据项目铁律，本轮部署不自动改写该文件，部署状态需另获明确授权后同步。
