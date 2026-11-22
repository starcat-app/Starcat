# Starcat 业务图标来源与映射

侧栏、设置、详情与 AI / RAG 工作台共用 `BusinessIcon.Symbol` 的业务映射。准确的 SF Symbols 保留；仅为语义缺口引入 Lucide 本地矢量资源，不添加图标运行时依赖或网络加载。

Fork 身份与次数另用 dong4j 确认的定制素材，来源与绘制约束见 [定制 Fork 图标](../custom/README.md)，不属于下面的 Lucide 许可范围。

## 来源与许可

- 上游仓库：<https://github.com/lucide-icons/lucide>
- 固定来源提交：`20aef31db93fe4d9f398dbb15b120d99c48eef95`
- `BusinessCuratedCollection`：`icons/library-big.svg`
- `BusinessAutomation`：`icons/workflow.svg`
- `BusinessInference`：`icons/brain-circuit.svg`
- `BusinessAIIndex`：`icons/file-search.svg`
- `BusinessLicense`：`icons/scale.svg`
- `BusinessEmbedding`：`icons/axis-3d.svg`
- `BusinessRecommendations`：`icons/scan-search.svg`
- `BusinessInsightsOverview`：`icons/chart-no-axes-column.svg`
- `BusinessKnowledgeProfile`：`icons/user-round.svg`
- 上述清单均不在固定提交的 Feather 衍生图标列表内，适用 ISC；随 App 保留完整声明于 `Starcat/Resources/Licenses/Lucide.txt`，并在 About 开源致谢登记。

SVG 保留上游路径、24×24 设计网格与圆角描边，默认线宽 2px；`BusinessInsightsOverview` 的三条独立直线视觉偏轻，单独加粗至 3px，与相邻主导航图标做光学匹配。Asset Catalog 将其作为单色矢量模板编译，不把 24px 设计网格当作显示尺寸。

## 业务语义对照

| 区域 / 功能 | 图形 | 处理与跨页面约束 |
|---|---|---|
| Awesome 精选清单 | Lucide `library-big` | 替换眼镜；侧栏、说明和空态同源 |
| AI 自动整理 | Lucide `workflow` | 不再与刷新共用循环箭头；设置导航、搜索建议和配置标题同源 |
| AI 索引 | Lucide `file-search` | 与检索放大镜分离；设置与后台任务同源 |
| RAG 推理 | Lucide `brain-circuit` | 与模型配置 CPU 分离；设置导航、搜索建议和后端标题同源 |
| 许可证 | Lucide `scale` | 不再用空间坐标或认证徽章；详情、筛选、洞察导航和分布区块同源 |
| Embedding | Lucide `axis-3d` | 用坐标维度区分 MCP 连线；模型能力、本地模型分类与用量统计同源 |
| 相似仓库推荐 | Lucide `scan-search` | 用匹配检索区分 MCP；详情入口、推荐弹层与推荐服务设置同源 |
| 个人知识画像 | Lucide `user-round` | 单人轮廓表达个人画像，沿用洞察侧栏图标规格 |
| CodeFlow | SF `flowchart` | 用流程节点区分 MCP；外链菜单、主推入口与面板标题同源 |
| Fork 身份 / 派生来源 | 定制 Y 形三节点 | 卡片标题、来源说明与隐藏 Fork 筛选一致，不与数量共用 |
| 被 Fork 次数 | 定制双箭头节点 | 卡片、详情、搜索与活动统计一致，保留既有语义色 |
| 发现 / 趋势 / 热门 / 新发布 / 周刊 | SF `safari` / `chart.line.uptrend.xyaxis` / `flame` / `shippingbox` / `newspaper` | 保留；趋势与发现的 Agent 来源不再错用火焰、星光 |
| Linux.do | SF `text.bubble` | 保留单气泡；侧栏、说明、空态一致 |
| Stars / 知识库 / 我的项目 | SF `star.fill` / `heart.fill` / `person.crop.rectangle.stack.fill` | 保留；Agent 知识库选择器与主侧栏一致 |
| 智能集合 / 语言 / 分组 / 标签 | 既有筛选 / globe / folder / tag 图标 | 保留用户自选图标；洞察的语言、未打标签与侧栏默认图标一致 |
| 通用 / 通知 / 快捷键 / Pro / 隐私 | 既有 gear / bell / keyboard / crown / shield 图标 | 保留；导航和搜索建议读取同一分类映射 |
| 模型 / 翻译 / 联网搜索 / MCP / 自建服务 | 既有 CPU / 字符气泡 / globe / 连线 / server 图标 | 保留；不以普通配置图替换供应商品牌标识 |
| 插件 / 本地工具 / 存储 / 诊断 / 实验室 | 既有 puzzle / hammer / drive / stethoscope / flask 图标 | 保留；设置 Section 的尺寸仍由共享标题组件负责 |
| 提示词 / RAG 检索 | SF `text.quote` / `magnifyingglass` | 保留；与推理及 AI 索引区分 |
| README / 笔记 / AI 摘要 / 仓库元数据 | SF `doc.richtext` / `note.text` / `doc.text` / `list.bullet.rectangle` | RAG 引用、命中列表、分片编辑器与详情内容语义同源；摘要不再使用翻译气泡，元数据不再冒充标签 |
| 代码上下文 | SF `chevron.left.forwardslash.chevron.right` | 设置、RAG 引用和 XML 编辑窗口同源，不再混用大脑、包裹 |
| 仓库健康 / OpenSSF | SF gauge / checkmark shield | 详情、列表与后台任务一致；我的洞察及仓库洞察健康度复用仪表盘，OpenSSF 状态图形保留 |
| AI 标签 / 仓库分组 | SF tag / folder | 工作区标题和后台任务同源；状态用的暂停、失败、上传等图标保留 |
| Agent 周报 / 分析 / 替代项目 / General / Research | SF newspaper / document search / branch / terminal / books | 保留；Agent 定义集中引用，rail 与执行区继续读取定义 |
| RAG 问答 | SF `bubble.left.and.text.bubble.right` | 问答窗口标题使用对话语义；已有 R 圆形品牌入口不替换 |

## 尺寸与状态规则

- 侧栏：沿用 16pt 图标列，SF 为 13pt semibold；Lucide 采用 16pt 画布，描边约 1.33pt，与紧凑 SF 图形做视觉配合。应用内字号倍率沿用现有 `InterfaceScale`。
- 设置：导航使用 16pt 图标列；Section 保留 20pt 占位、13pt medium SF 与 16pt 矢量画布。标题、按钮、间距与表单布局不变。
- 详情：许可证徽章使用 11pt 图形，保留原胶囊内边距；其他内容、来源与状态图标保持原场景字号。
- 颜色由外层提供，资产作为 template 接受 `.primary` / `.secondary` 或既有业务语义色；侧栏选中反白仍由 `SidebarSemanticIconStyle` 解析，不能根据 selection binding 猜测。
- 系统关闭、刷新、复制、删除、重置、发送、停止、状态提示与展开箭头继续使用原共享控件；供应商品牌、仓库头像、编程语言标识、用户自选标签图标不替换。
- 不新增文案或本地化 key，不改变任务、导航、筛选、缓存或写入逻辑。以后新增语义先加入集中映射，并同步资源测试、许可与此对照表。

## 验证边界

`BusinessIconTests` 验证打包模板、SF 可用性、跨页面映射与离屏尺寸；不能替代 GUI 观感验收。明暗主题的真实选中态、视觉重量和基线仍需在应用内人工确认，不因构建通过宣称视觉验收完成。
