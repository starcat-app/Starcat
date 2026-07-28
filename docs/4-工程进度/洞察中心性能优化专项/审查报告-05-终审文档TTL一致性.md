# 洞察中心性能优化审查报告 05：终审文档 TTL 一致性

> 审查日期：2026-07-29
>
> 审查范围：详细设计、实现、Checklist、提交与最终构建
>
> 结论：代码无新增问题；发现 1 个 P2 文档冲突，本轮不计入连续 Clean。

## 1. 已通过

- 完整 `build-for-testing` 再次通过。
- `git diff --check`、String Catalog JSON / 格式、提交消息规范检查通过。
- 切库屏障、请求预算、ETag / 304、失败退避、热点缓存和本地 Snapshot 未发现新增 P0 / P1 / P2。
- 未修改 `docs/功能实现总览.md`，未触碰 dong4j 的三个无关工作区文档。

## 2. P2：详细设计旧 TTL 表未同步

`49-洞察中心详细设计.md` 前半段既有缓存表仍写：

- `communityProfile | 24 小时`

但代码、测试、Checklist 和新增性能回填均已调整为：

- `communityProfile | 3 天`

同一文档内部口径冲突，后续开发者可能按旧表回退实现。

## 3. 修复要求

1. 把既有缓存表的 Community TTL 同步为 3 天。
2. 同表补充 Security 6 小时，避免只在性能回填章节出现。
3. 修复后重新开始连续两轮 Clean 复审计数。
