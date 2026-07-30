# 我的项目专项审查报告：第 9 轮导航与 Stargazers 说明

> 审查日期：2026-07-29
>
> 审查分支：`dev`
>
> 审查范围：Sidebar 导航顺序、Star History 数据来源说明、i18n、单元测试、设计文档、专项进度与提交边界
>
> 结论：**代码与自动化验证通过；发现 4 项文档和进度一致性问题，需修复后复审**

## 1. 功能审查

1. `SidebarView` 已将“我的项目”移动到“全部仓库”之前，未改变 selection、计数或查询语义。
2. Star History 在存在 `.githubStargazers` 来源时不显示限制说明；公共估算、本机快照、Private-only 和 unavailable 状态显示轻量说明。
3. 说明文案明确区分“可用的估算数据”和“本机快照”，没有把所有非项目仓库误写为只能使用本地数据。
4. “查看 GitHub 公告”链接指向 GitHub 官方 2026-06-30 API 访问限制公告。
5. loading、building 和 failed 状态不显示限制说明，避免与主要状态反馈竞争。

本轮未发现代码功能缺口。

## 2. 自动化证据

以下检查通过：

1. `StarHistoryRestrictionNoticePolicyTests`
2. `StarHistoryChartSeriesBuilderTests`
3. `StarHistoryViewModelTests`
4. Debug `xcodebuild build`
5. `Localizable.xcstrings` JSON 解析
6. `git diff --check`
7. i18n 禁用调用扫描未新增生产调用

## 3. 发现的问题

### 3.1 详细设计的 Sidebar 顺序已过期

`51-我的项目整体落地方案.md` 仍写“我的项目”位于“全部仓库”之后，且信息架构示意顺序与当前产品要求相反。

### 3.2 Checklist 未登记本轮修订

专项 checklist 尚未记录“我的项目置顶”“非精确 Stargazers 来源说明”和第 9 轮审查。

### 3.3 最终复审报告的审查轮次与结论未更新

报告仍以“五轮审查闭环”为标题，只在后续章节记录到第 8 轮，未覆盖本轮导航与说明修订。

### 3.4 结果报告的交付与审查记录未更新

结果报告仍描述五轮专项审查，Star History 修订仅记录到第 8 轮，缺少本轮官方限制说明、显示策略测试与 Sidebar 新顺序。

## 4. 修复要求

1. 将详细设计中的 Sidebar 顺序改为“我的项目”在“全部仓库”之前。
2. 回填 checklist 的 UI 项与第 9 轮审查项。
3. 更新最终复审报告和结果报告，使代码、验证证据、轮次和 Git 分支事实一致。
4. 修复后执行 Markdown 差异检查、`git diff --check` 和最终工作区审计。

## 5. 边界

- 本轮不修改 `docs/功能实现总览.md`。
- 本轮不执行 push。
- GitHub Stargazers 重建来源仍只代表当前保持 Star 的用户，不能恢复已取消 Star 的历史峰值。
