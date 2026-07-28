# 洞察中心性能优化审查报告 06：TTL 修复后第一轮 Clean 复审

> 审查日期：2026-07-29
>
> 结论：无新增 P0 / P1 / P2；连续 Clean 第 1 轮。

## 审查结果

- 设计表与 `RepositoryInsightsDataset.timeToLive` 完全一致：15 分钟、24 小时、3 天、6 小时。
- Recent Activity 的缓存 range 固定为 `all`；Activity 仍按 week / month / quarter / year 分区。
- 全仓旧口径搜索只命中审查报告中的历史问题描述，没有存量设计冲突。
- 切库 begin / end 屏障、请求预算、ETag / 304、失败退避、LRU 和本地 Snapshot 未发现回退。
- 最新完整 `build-for-testing` 已通过；本轮仅修改文档，无需重新生成工程。
- `git diff --check`、String Catalog、提交消息、Star History 非目标和 `docs/功能实现总览.md` 只读边界均通过。
- Checklist 的 test host 与人工验收仍保持未勾选，未伪造不可观察结果。
