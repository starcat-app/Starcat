# 洞察中心性能优化审查报告 04：修复后第一轮 Clean 复审

> 审查日期：2026-07-29
>
> 审查范围：`4d619399..1963c8d4`
>
> 结论：无新增 P0 / P1 / P2；第一轮 Clean。

## 1. 切库屏障

- begin 在取消旧请求前先关闭入口，新请求不会提前读取 Token。
- 已进入的普通请求由 in-flight tracker 取消；observer 请求自然结束，二者均计入 drain。
- `database.reopen` 成功和失败路径都会调用 end，不存在永久挂起。
- end 后等待请求重新读取当前 Token；测试同时断言屏障期间 HTTP 请求数为 0。
- 页面仍以 `databaseScopeRevision` 让旧 generation 失效，不改变现有 UI 和动画。

## 2. 缓存、请求数与失败路径

- 完整冷加载正常路径为 5 次请求，Activity 与 Recent 共享唯一 GraphQL。
- warm、stale、miss、304、concurrent、account-switch 均有对应测试源码。
- 304 payload 丢失重拉、404 / 422 负缓存、401 不缓存、指数退避和 Rate Limit 均与设计一致。
- 解码 LRU、单事务本地 Snapshot、TTL 和 Star History 非目标未发生回退。

## 3. 工程一致性

- 最新 `build-for-testing` 通过，包含新增屏障测试编译。
- `git diff --check`、String Catalog JSON / 格式检查通过；本轮没有新增本地化 key。
- `docs/功能实现总览.md` 未修改。
- Star History 代码与设计文件相对基线无差异。
- Checklist 为 57 / 64；未执行 test host、结果报告和四项人工验收保持未勾选，状态真实。
- 工作区仍有 dong4j 的三个无关文档改动，本专项未暂存、修改或提交这些文件。
