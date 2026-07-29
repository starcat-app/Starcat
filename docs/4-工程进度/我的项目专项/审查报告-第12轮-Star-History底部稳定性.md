# 我的项目专项审查报告：第 12 轮 Star History 底部稳定性

> 审查日期：2026-07-29
>
> 审查分支：`dev`
>
> 审查范围：Star History 图表选中态、底部图例与元数据布局、i18n、单元测试、Debug 构建及专项文档
>
> 结论：**代码和自动化验证通过；发现专项设计与进度文档仍保留旧的动态读数口径，需要同步修订**

## 1. 代码审查

1. 图表选中日期只更新图内 `RuleMark` 与浮层，不再向 footer 插入或移除读数，消除交互时的垂直高度变化。
2. 图例与“日期范围 · 更新时间”固定在同一行：图例靠左，稳定元数据靠右。
3. 单一精度时继续隐藏图例，元数据仍保持右对齐；多精度时保留图例以区分数据来源。
4. GitHub Stargazers 限制短链接只在需要时占用第二行，不影响精确 Stargazers 场景的单行 footer。
5. 删除仅服务于旧动态读数的格式化方法和本地化键，未保留无效兼容路径。

本轮未发现新的代码功能缺口。

## 2. 自动化证据

以下检查通过：

1. `StarHistoryDisplayPolicyTests`
2. `StarHistoryRestrictionNoticePolicyTests`
3. `StarHistoryChartSeriesBuilderTests`
4. `StarHistoryViewModelTests`
5. Debug `xcodebuild build`
6. `Localizable.xcstrings` JSON 解析
7. `git diff --check`
8. i18n 禁用调用和 `.tertiary` 静态检查未新增违规

## 3. 发现的问题

1. `51-我的项目整体落地方案.md` 仍描述“选中日期后显示底部读数”和 `ViewThatFits` 两行回退，与当前稳定 footer 实现不一致。
2. 专项 checklist、最终复审报告和结果报告仍停在第 11 轮，尚未记录本轮底部稳定性修订。

## 4. 修复要求

1. 将设计口径改为“图内展示选中读数，footer 不展示动态读数”。
2. 记录图例左对齐、日期范围与更新时间同排右对齐，以及限制短链接按需占第二行的布局规则。
3. 将专项审查轮次更新为第 12 轮，并同步 checklist、最终复审报告和结果报告。
4. 修复后执行 Markdown 差异检查、`git diff --check` 与最终工作区审计。

## 5. 边界

- 本轮不修改 `docs/功能实现总览.md`。
- 本轮不执行 push。
- 真实 macOS 窗口宽度、VoiceOver 与 Light / Dark 仍属于发布前人工验收 Gate，不伪造完成证据。
