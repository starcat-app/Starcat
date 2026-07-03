# 知识库 RAG 需求讨论

> 日期: 2026-07-03
> 状态: 需求确认, 进入正式方案与详细设计
> 范围: 本地 RAG 的知识源边界、入口形态、UI/UX 与落地路线

## 1. 背景

早期 `30-本地RAG设计.md` 把 RAG 的数据来源定义为“已 star 仓库”。这个判断在当时合理,因为 Starcat 的主要数据入口就是 GitHub Stars。

但现在 Starcat 已经拆出了“知识库”概念:

- `starred` 是 GitHub 公开 Star 行为和同步来源。
- `libraryState == .inLibrary` 是 Starcat 私有知识管理边界。
- 已 star 不代表值得长期整理、问答和引用。
- 未 star 的外部 repo 也可以因为研究价值进入知识库。

因此 RAG 不能继续默认吃所有 starred。RAG 的价值是“基于我真正整理过、认可进入知识库的项目回答问题”,而不是把全部 GitHub Star 当成长期知识资产。

## 2. 核心问题

本次需求讨论围绕三个问题:

1. RAG 的数据来源应不应该只来自知识库。
2. RAG 是否需要独立入口,还是塞进现有搜索或 Agent 页面。
3. RAG 的回答如何让用户信任,并能回到 repo 继续阅读。
4. issues / releases / PR 等未本地存储的数据,是否可以作为本轮上下文辅助回答。

初步结论:

- RAG 默认只使用知识库 repo,不使用全部 starred。
- RAG 可以保留“扩展到 starred”的诊断/调试能力,但不作为默认产品心智。
- RAG 需要独立工作台入口,不应只是语义搜索的一个 mode。
- RAG 回答必须带引用、证据片段和可点击 repo 入口。
- RAG 不做通用联网 web RAG,但可以对本轮候选 repo 拉取受控的远程临时上下文。
- RAG 技术方向是 Local-First Hybrid RAG,默认本地 FTS + 向量检索,Meilisearch / Qdrant 只作为后续自托管增强选项。

## 3. 为什么 RAG 只吃知识库

RAG 与语义搜索不同。

语义搜索的目标是“帮用户找可能相关的 repo”,范围可以是 starred、knowledge 或 all。即使命中了一些不重要的 repo,用户也只是看到列表,可以自己跳过。

RAG 的目标是“替用户组织答案”。如果数据源里混入大量只是随手 star、并不真正关心的项目,LLM 会把这些项目当成同等可信的材料,答案会被稀释,甚至把用户并不认可的 repo 推荐出来。

所以 RAG 的默认数据边界应更窄:

> 只有进入 Starcat 知识库的 repo,才是 RAG 默认可引用的项目数据来源。

这个边界与知识库产品语义一致: 用户点击 ❤️ 入库,就表示这个 repo 可以进入长期整理、检索、AI 摘要、RAG 问答和导出的私有知识管理体系。

## 4. 与现有能力的关系

| 能力 | 默认范围 | 输出形态 | 说明 |
|---|---|---|---|
| Manage 搜索 | starred | repo 列表 | 管理 GitHub Stars |
| 全局搜索中心 | local / GitHub / web | repo / 页面候选 | 找东西,不是组织答案 |
| 语义搜索 | starred / knowledge / all | repo 列表 + 语义分 | 召回相关 repo |
| 单仓 AI 摘要 | 当前 repo | 摘要 / 标签建议 | 用户显式触发,不要求入库 |
| Agent 工作台 | 任务上下文 | 步骤 + artifact | 多步任务和报告 |
| 知识库 RAG | knowledge | 回答 + 引用 + 证据 | 基于知识库生成答案 |

RAG 应复用语义搜索和 AI 调用链,但产品上不是“搜索增强”,而是“知识库问答”。

## 5. 入口讨论

现有 Agent 已有专属覆盖式工作台,适合承载多步骤任务、工具调用、产出物和人工确认。RAG 也需要沉浸式空间,但它的使用频率和心智不同:

- RAG 是日常问答入口,用户可能频繁打开、追问、点引用。
- Agent 是任务入口,更适合“生成周报、整理标签、扫描重叠项目”这类明确工作流。
- RAG 的核心不是执行任务,而是基于知识库给出可追溯回答。

因此第一版建议做独立的“知识库问答”工作台:

- 主窗口覆盖式页面,与 Agent Workspace 同级。
- 可以复用 Agent 的 Run Surface 思路: 左侧会话/范围,中间问答流,右侧证据 Inspector。
- 入口先放在 toolbar 或 Smart Collections -> 知识库页的醒目动作中,未稳定前可继续 Debug gate。

不建议第一版直接塞进:

- 搜索框 mode: 搜索与问答心智差异太大。
- 详情页 AI 浮层: RAG 是跨 repo 问答,不是单仓库摘要。
- Agent 列表: 容易让用户以为它是一次性任务,而不是常用知识库问答。

## 6. 第一版体验轮廓

用户打开“知识库问答”后看到:

1. 顶部显示当前范围: `知识库`、repo 数、索引覆盖率。
2. 中间是问答流: 用户提问,Starcat streaming 输出回答。
3. 右侧是证据 Inspector: 展示本轮引用到的 repo、README/notes/summary chunk、相似度、来源。
4. 引用 chip 可点击打开 repo 详情。
5. 当知识库为空或索引不足时,引导用户去知识库集合或设置页补索引。
6. 当问题明确涉及 issues、版本、PR、维护活跃度等现场信息时,可显示“GitHub 临时上下文”并对候选 repo 拉取本轮数据。
7. 输入框支持 `@repo`、模型切换下拉、附件和 GitHub 链接识别,让用户能直接指定上下文。

典型问题:

- “我的知识库里有哪些适合做本地 RAG 的 Swift 项目?”
- “我收藏进知识库的 macOS 工具里,哪些支持 menu bar 常驻?”
- “帮我对比知识库里的几个向量数据库项目,给出适合桌面 app 的选择。”
- “我之前入库过哪个项目适合做 Markdown 渲染?”
- “这些项目最近有没有比较集中的 issue 或兼容性反馈?”

### 6.1 输入体验讨论

RAG 的易用性很大程度取决于输入框。用户不一定总想让系统从整个知识库里猜,很多时候会直接指定几个 repo 做分析或对比。

因此输入框需要支持类似 Codex / Claude 的 Command Composer:

- 输入 `@` 弹出知识库 repo list,支持选择一个或多个 repo。
- 选中的 repo 作为本轮显式上下文,默认限制 RAG 只在这些 repo 中回答。
- 输入框内提供模型切换下拉,可切换本轮模型,但不自动修改全局设置。
- 是否查询 issues / releases 不通过输入框命令触发,而由 Query Planner 判断后在流程中展示给用户确认。
- 图片和附件可以作为本轮临时上下文,不进入知识库索引。
- 粘贴 GitHub 链接时,如果 Starcat 已有该 repo,优先转为内部 repo chip;否则保留外部 GitHub 链接。

这个设计的目的不是堆功能,而是减少用户为了“指定范围、切换模型、附带材料”反复去设置页或搜索页的成本。

## 7. 远程临时上下文

Starcat 目前不存储 repo issues,也不打算把 issues 作为长期本地数据。但用户提问时,issues、releases、PR、contributors 等 GitHub 现场信息可能很有价值。

因此这里的产品边界是:

- 本地 RAG 索引仍只来自知识库 repo 的 README、notes、AI summary、repo metadata。
- issues / releases / PR 不进入 chunk 索引,不生成 embedding,不写入 CloudKit。
- 只有当用户问题明确需要这类信息时,才对本轮候选 repo 临时拉取。
- 远程数据只补充候选 repo,不能绕过知识库边界变成 GitHub 全网搜索。
- 如果 GitHub rate limit、无权限或网络失败,回答应明确说明该部分不可用,并继续基于本地知识库资料回答。

这能解决“本地知识库稳定性”和“现场信息时效性”的矛盾: RAG 的主证据链仍是用户认可的知识库,但必要时可以把 GitHub issues 这类临时上下文给到 LLM 做总结。

## 8. 已确认边界

- 默认 RAG 不引用未入库 starred repo。
- 单仓 AI 摘要仍允许用户对未入库 repo 显式触发。
- 语义搜索继续保留 starred / knowledge / all 范围,不因为 RAG 默认知识库而收窄。
- 第一版不要求用户部署 Meilisearch / Qdrant;这些只作为高级自托管 provider。
- RAG 回答必须显示“基于知识库资料”,不能暗示已经访问到当前无权限的 GitHub 内容。
- 资料不足时必须明确说不足,并给出“去 GitHub / AnySearch 搜索”“拉取候选 repo 的 GitHub 临时上下文”或“把相关 repo 加入知识库”的下一步。
- 远程临时上下文只在用户提问触发后拉取,不做后台常驻抓取。
- 第一版不让 RAG 自动修改 tags、notes、status、star 或 libraryState。
- 如果后续 RAG 给出整理建议,必须走人工确认动作,不能直接写库。

## 9. 初步结论

本次 RAG 重设计从“已 star 仓库问答”调整为“知识库问答”:

1. 数据边界: `libraryState == .inLibrary`。
2. 技术路线: 在现有 repo-level embedding 之上新增 chunk-level Hybrid RAG 索引,本地 FTS 与向量检索并行召回。
3. 入口形态: 独立知识库问答工作台,与 Agent Workspace 同级但心智不同。
4. 输出要求: streaming markdown 回答 + 引用 chip + 证据 Inspector。
5. 上下文增强: issues / releases / PR 等只作为本轮远程临时上下文,不进入本地 RAG 索引。
6. 可选增强: 后续允许用户在 Settings 中接入自托管 Meilisearch / Qdrant。
7. 落地节奏: 先做只读问答闭环,再扩展历史、导出、建议动作和 Agent 联动。
