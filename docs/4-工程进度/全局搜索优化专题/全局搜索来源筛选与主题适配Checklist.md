# 全局搜索来源筛选与主题适配 Checklist

> 状态：2026-11-13 本轮 U1–U3 实现与自动化检查全部完成，界面人工验收另行记录。
>
> 工作区：`Starcat-global-search-content-filter`，分支 `codex/global-search-content-filter`，本轮基线 `2242ecc0`。
>
> 决策：[开发前问题清单](../../1-立项/开发前问题清单.md)“来源筛选与切换反馈”；不改写原内容过滤与搜索优化 Checklist 的历史完成状态。

| 状态 | 编号 | 小功能 | 验收 |
|---|---|---|---|
| [x] | U1 | 底部来源单选筛选 | 关键词、语义、GitHub、网页、智能发现可点击；再点恢复；多来源去重、独立计数、零命中、键盘选中、范围与新提交重置、关闭重开保留、筛选不发请求有回归覆盖；58 项定向测试通过 |
| [x] | U2 | 来源胶囊与徽标主题适配 | 关键词蓝、语义紫、GitHub 橙、网页绿、智能发现 Accent；选中态增强背景与描边；文字图标使用语义前景色；明暗主题分别配置；右侧徽标共用中性底座并保持 20pt 及原有留白；Direct 构建通过 |
| [x] | U3 | 范围与来源切换过渡 | 160ms 淡入淡出；减少动态效果时关闭；动画只绑定用户切换的列表身份，搜索结果与分页追加不重播；87 项定向回归、Direct 构建与差异检查通过 |

## 验证记录

- U1：`make test TEST_ARGS="-only-testing:StarcatTests/SearchCenterViewModelTests -only-testing:StarcatTests/SearchCoordinatorTests"`，58 项 / 2 Suite 通过，日志 `/tmp/starcat-source-filter-u1-test.log`。包含新增来源筛选回归，以及已选来源失败后仍可取消筛选。
- U2：`make build-direct` 通过，日志 `/tmp/starcat-source-filter-u2-build.log`；构建脚本完成 Direct 产物与签名校验，未停止或启动应用。徽标尺寸、尾部预留和胶囊内边距保持原值。
- U3：`make test TEST_ARGS="-only-testing:StarcatTests/SearchCenterViewModelTests -only-testing:StarcatTests/SearchCoordinatorTests -only-testing:StarcatTests/RepositoryDiscoveryServiceTests -only-testing:StarcatTests/SearchContentPolicyTests"`，87 项 / 4 Suite 通过，日志 `/tmp/starcat-source-filter-u3-test.log`。新增在途来源完成、分页追加保持筛选和列表身份的回归。
- U3：`make build-direct` 通过，日志 `/tmp/starcat-source-filter-u3-build.log`；Direct 产物与签名校验通过，未停止或启动应用。`git diff --check`、专题及分支文档相对链接检查通过；本轮没有新增本地化 key。

构建通过不代表界面与明暗主题已人工验收；本轮不关闭整个全局搜索专项。
