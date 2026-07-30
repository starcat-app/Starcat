# 我的项目专项审查报告：第 8 轮 Star History 折线连续性

> 审查日期：2026-07-29
>
> 审查分支：`dev`
>
> 审查范围：Star History Swift Charts 分组、来源切换、单快照渲染和回归测试
>
> 结论：**发现的折线断开问题已修复，自动化验证通过**

## 1. 现象

GitHub 当前 Stargazers 重建曲线结束于最后一个 `starred_at` 日期，本机精确快照位于当前日期。两者 Stars 数相同，但图表只显示重建虚线和右侧独立快照点，中间没有连接线；面积填充仍连续。

## 2. 根因

1. `AreaMark` 使用全部 `displayedStarPoints`，所以填充区域连续。
2. `LineMark` 按 `estimated`、`reconstructed`、`snapshot` 分成不同 series。
3. Swift Charts 不会自动连接不同 series。
4. 当前本机 `snapshot` 只有一个点，单点只能绘制 `PointMark`，无法形成折线。

该问题只影响可视化连续性，不代表历史数据缺失。

## 3. 修复

1. 新增纯数据转换 `StarHistoryChartSeriesBuilder.bridges(in:)`。
2. 相邻点精度发生变化时生成独立两点桥接段；同一精度内部不重复生成。
3. 桥接段沿用前一来源的线型：估算和重建保持虚线，精确快照保持实线。
4. 桥接使用线性插值，避免在长时间空档中由 Catmull-Rom 产生额外波动。
5. 精确快照点绘制在桥接段之上，继续保留当前观测点的视觉强调。

## 4. 自动化证据

以下检查均通过：

1. `StarHistoryChartSeriesBuilderTests`
2. `StarHistoryViewModelTests`
3. `RepoStarHistoryRepositoryTests`
4. Debug `xcodebuild build`
5. `git diff --check`
6. UI 颜色静态检查未新增 `.tertiary`

新增测试直接复现截图数据：`2023-10-22 · 15` 的 GitHub 重建点连接至 `2026-07-29 · 15` 的本机快照，并确认生成的桥接段继承 `reconstructed` 精度。

## 5. 边界

- 连接线只表达相邻观测点之间的连续趋势，不声称掌握空档期内每次 Star / Unstar 事件。
- GitHub 当前 Stargazers 仍无法还原已经取消 Star 的用户和历史峰值。
- 本轮未修改 `docs/功能实现总览.md`，未执行 push。
