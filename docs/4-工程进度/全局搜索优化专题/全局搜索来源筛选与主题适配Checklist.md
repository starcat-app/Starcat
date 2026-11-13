# 全局搜索来源筛选与主题适配 Checklist

> 状态：2026-11-13 dong4j 确认实施；当前进行中，界面人工验收另行记录。
>
> 工作区：`Starcat-global-search-content-filter`，分支 `codex/global-search-content-filter`，本轮基线 `2242ecc0`。
>
> 决策：[开发前问题清单](../../1-立项/开发前问题清单.md)“来源筛选与切换反馈”；不改写原内容过滤与搜索优化 Checklist 的历史完成状态。

| 状态 | 编号 | 小功能 | 验收 |
|---|---|---|---|
| [x] | U1 | 底部来源单选筛选 | 关键词、语义、GitHub、网页、智能发现可点击；再点恢复；多来源去重、独立计数、零命中、键盘选中、范围与新提交重置、关闭重开保留、筛选不发请求有回归覆盖；58 项定向测试通过 |
| [ ] | U2 | 来源胶囊与徽标主题适配 | 胶囊按来源着色、选中态明确；文字图标使用语义前景色；明暗主题区分背景与描边；右侧徽标保持 20pt 及原有留白；Direct 构建验证 |
| [ ] | U3 | 范围与来源切换过渡 | 约 160ms 淡入淡出；减少动态效果时关闭；搜索结果与分页追加不重播整列表过渡；完整定向回归、Direct 构建与差异检查 |

## 验证记录

- U1：`make test TEST_ARGS="-only-testing:StarcatTests/SearchCenterViewModelTests -only-testing:StarcatTests/SearchCoordinatorTests"`，58 项 / 2 Suite 通过，日志 `/tmp/starcat-source-filter-u1-test.log`。包含新增来源筛选回归，以及已选来源失败后仍可取消筛选。

构建通过不代表界面与明暗主题已人工验收；本轮不关闭整个全局搜索专项。
