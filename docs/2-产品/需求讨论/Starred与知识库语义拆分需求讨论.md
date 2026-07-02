# Starred 与知识库语义拆分需求讨论

> 日期: 2026-07-02
> 状态: 需求确认, 进入正式方案与详细设计
> 范围: GitHub starred 与 Starcat 私有知识库的语义拆分、入口交互、AI/MCP 可用范围

## 1. 背景

Starcat 当前以 GitHub starred repos 作为主要数据入口。这个入口天然合理,因为用户已经用 GitHub Star 做过一次轻量筛选,Starcat 可以同步这些仓库并提供搜索、标签、笔记、README、AI 摘要、语义搜索等能力。

但实际使用中,GitHub Star 不总是代表“会使用”或“值得进入知识库”。用户可能因为以下原因 star 一个 repo:

- 项目热门,先标记一下。
- 概念有趣,但不符合当前技术栈。
- 支持作者或表达认可。
- 临时保存,以后不一定会看。
- 只是公开 GitHub 行为,不希望进入私有知识管理系统。

如果 Starcat 把所有 starred repos 都默认视为 AI 知识库,会产生两个问题:

- AI/语义搜索上下文被大量“只是感兴趣”的 repo 稀释。
- 用户无法区分 GitHub 公开 Star 行为与 Starcat 私有知识库行为。

因此需要把 `starred` 与“知识库”拆成两个不同概念。

## 2. 核心语义

本次讨论确认以下语义边界:

| 概念 | 所属系统 | 含义 | 是否公开 | AI/MCP 可用性 |
|---|---|---|---:|---:|
| Starred | GitHub | 用户当前是否 star 了该 repo | 是 | 可用 |
| 知识库 | Starcat | 用户明确认为该 repo 值得长期整理、搜索、总结和作为 AI 上下文 | 否 | 可用 |
| 正在使用 | Starcat | 用户当前正在使用或重点关注的 repo | 否 | 可用,且优先级更高 |

一句话原则:

> Starred 是 GitHub 来源信号,知识库是 Starcat 私有入库信号;AI/MCP 不把两者互斥,而是提供清晰的范围选择。

## 3. 产品目标

本次改造的目标不是取消 starred 入口,而是在 starred 之上增加一层 Starcat 私有筛选:

1. GitHub starred 继续作为同步入口和 Inbox。
2. 用户通过明确动作把 repo 加入知识库。
3. AI 索引、语义搜索、AI 对话上下文和 MCP 同时支持 starred 与知识库两个范围,避免把任一侧能力阉割。
4. 未 star 的外部 repo 也允许加入知识库,但不会自动帮用户 star。
5. Star 与加入知识库必须是两个独立动作,避免把私有知识管理行为变成 GitHub 公开社交行为。

## 4. 入口讨论

用户明确希望“加入知识库”的入口放在详情页中,位于当前 Wiki / 推荐等图标之后,新增一个常驻 ❤️ 图标。

本次确认的交互原则:

- ❤️ 是 Starcat 私有知识库动作。
- ⭐ 仍是 GitHub Star 动作。
- ❤️ 不替代 ⭐,也不自动触发 ⭐。
- 入口常驻在详情页动作区,已入库与未入库用不同视觉状态区分。
- 点击 ❤️ 后需要有一定动画反馈,强化“已加入知识库”的确认感。

状态与文案:

| 状态 | 图标 | 文案 / tooltip | 点击后 |
|---|---|---|---|
| 未入库 | 空心心形 | `加入知识库` | 加入知识库 |
| 已入库 | 实心心形 | `已入库` | 取消入库 |

本入口按 GitHub Star 的二态 toggle 模型设计:空心表示未入库,实心表示已入库。点击已入库状态即取消入库,但 UI 不额外常驻展示“取消入库”“未整理”“忽略”等文案或状态。

不建议用“收藏”作为主要 UI 文案,因为中文用户容易把它与 GitHub Star 混淆。内部可把字段命名为 `libraryState`,但状态只表达未入库 / 已入库,UI 使用“知识库/入库”。

## 5. 未 star repo 是否允许加入知识库

结论: 允许。

理由:

- 加入知识库是 Starcat 私有动作,不应要求用户在 GitHub 上公开 Star。
- Search Center、Discovery、Trending、Weekly、Browser Plugin 页面中的外部 repo,可能对用户有学习或研究价值,但用户未必想 star。
- Starcat 的知识管理边界应由用户私有意图决定,不是由 GitHub 公开状态决定。

对应状态组合:

| GitHub Star | Starcat 知识库 | 含义 |
|---:|---:|---|
| 否 | 否 | 普通外部 repo |
| 是 | 否 | 已 star,但未入库 |
| 否 | 是 | 私有知识库 repo |
| 是 | 是 | 已 star 且已入库的核心资产 |

对未 star repo 的交互:

- 主动作仍是 `加入知识库`。
- 可提供次级动作 `Star` 或加入成功后的轻量操作 `同时 Star`。
- 不弹强制选择弹窗,避免打断“先私有保存”的主流程。

## 6. 智能集合入口

知识库应作为内置智能集合加入 Smart Collections,与“正在使用”同级:

- 知识库: `libraryState == .inLibrary`
- 正在使用: `RepoStatus.using`

知识库不是普通自定义智能集合。它是 Starcat 私有入库边界,应做成系统内置集合,避免被用户删除或改成无关规则。AI/MCP 可以使用知识库,也可以继续使用 starred 或两者并集。

## 7. 列表卡片入库标识

详情页 ❤️ 是单 repo 的主要入库入口,但列表浏览时也需要能一眼看出 repo 是否已经进入知识库。

第一版在 repo 卡片的 repo logo 左上角展示 ❤️ 标识:

- Manage / Trending / Discovery / Weekly / Activity 的 repo 卡片都需要支持。
- 标识只表达“已入库”,未入库不额外显示空心心,避免列表噪音。
- 位置固定在 repo logo 左上角,不要挤占标题行,也不要替代现有 GitHub Star 标识。
- GitHub Star 的 ✓/⭐ 仍表示公开 star 状态;❤️ 只表示 Starcat 私有知识库状态。
- Activity 中 repo-backed 卡片即使未来不再全是 starred,也应按 library state 显示 ❤️。

这个标识是浏览识别信号,不是主要操作入口。点击加入/取消入库的主入口仍放在详情页动作区,避免列表 row 同时承担选择、跳转、多选和入库 toggle 导致误触。

## 8. 已确认边界

- Manage / Trending / Discovery / Weekly / Activity 的 repo logo 左上角 ❤️ 只是状态标识,不可点击。
- Search Center 搜索结果需要展示入库状态,并允许直接加入/移出知识库。
- Search Center 的可操作 ❤️ 放在搜索结果 row 的 trailing action 区或详情/预览动作区,不要把 logo 角标做成可点击。
- Browser Plugin 可以提供与详情页一致的空心/实心 ❤️ 操作入口。
- Browser Plugin 操作失败时显示插件内 toast,并回滚 ❤️ 状态。
- 移出知识库只改变 `libraryState`,保留 notes、tags、status、Releases 订阅关系、repo metadata、README、Health、OpenSSF 和 embedding 缓存。
- 移出知识库后,如果 repo 同时不在 starred 与知识库,后续 release 轮询不再把它作为 active scope 自动刷新;重新 star 或重新入库后恢复自动刷新候选。
- GitHub repo 删除、转私有、404/410 或权限不足时,不自动移出知识库;知识库集合仍保留该 repo,但 UI 标记为不可访问/已失效。
- 已入库的私有 repo 或权限 repo 在没有 GitHub token / token 权限不足时,知识库状态和本地 notes/tags/status 可用;需要 GitHub 访问的能力降级。
- 已登录但离线时,允许修改本地已有 repo 的知识库状态;未登录时不允许加入或移出知识库。
- 未 star 已入库 repo 允许完整使用本地 notes / tags / status;这些能力以“已入库或已 star”为本地知识管理边界。GitHub star/unstar、远程刷新等能力仍按 GitHub 状态和 token 权限分层。
- Releases 订阅允许未 star 已入库 repo 使用;订阅关系是 Starcat 本地关注能力,实际 release 拉取仍受 token、权限和 repo 可访问性影响。
- Watchers / Forks / Issues 等 GitHub 统计刷新候选覆盖 starred 与知识库并集;权限不足、私有或不可访问时跳过或降频,不改变 `libraryState`。
- 用户手动触发单个 repo 的 README / Health / OpenSSF 刷新时,未 star 已入库 repo 也允许执行;失败只展示权限/不可访问/刷新失败反馈,不改变 `libraryState`,不删除已有缓存。
- Manage 默认仍是 starred 管理视图,不混入未 star 已入库 repo;全量知识库入口放在 Smart Collections -> 知识库。
- 知识库集合排序采用 `COALESCE(starred_at, library_updated_at, cached_at) DESC`;未 star 已入库 repo 主要按 `library_updated_at DESC` 排序。
- 加入知识库后的默认 `RepoStatus` 为 `unread`;如果是从 `using` 自动入库,则保持 `using`。
- 知识库集合支持现有 tag / status / language / archived / fork 筛选。
- Star/unstar 不自动改变知识库状态。已 star 且已入库的 repo 被 unstar 后仍保持 `.inLibrary`。
- `libraryState` 后续需要随 CloudKit 用户数据同步,但 CloudKit 尚未集成,第一版只记录设计约束。
- `libraryState` 必须按 GitHub 登录用户隔离。A 账号加入知识库的 repo,切换到 B 账号后不能显示为 B 的已入库。
- 退出登录或切换账号时,本地已有 `libraryState`、notes、tags、status 保留但隐藏;重新登录同一 GitHub 账号后恢复可见。只有用户显式清除本地数据或删除账号数据时才删除。
- JSON 导入/导出需要包含 `libraryState` 与 `libraryUpdatedAt`;导入 `.inLibrary` 只恢复 Starcat 私有入库状态,不调用 GitHub star。
- JSON 导入按当前登录账号恢复用户私有数据,不携带原导出账号作为写入归属;未登录时不允许导入会写入 `libraryState` 的数据。
- `libraryUpdatedAt` 只在 `libraryState` 实际变化时更新;notes/tags/status、不可访问状态变化不更新。
- 多选第一版只支持批量加入知识库,不提供批量移出知识库。
- 设置 `RepoStatus.using` 自动入库时给轻量 toast,不弹确认。
- 只有 `using` repo 移出知识库时需要二次确认,文案必须说明会把状态从“正在使用”改为“已读”;普通已入库 repo 移出时不弹确认。
- ShareCard 的文件导出能力需要同时支持 Starred 和知识库。原“导出 Starred”入口文案改为“导出到文件”,下拉项为“导出 Starred 到 HTML / 导出 Starred 到 Markdown / 导出 知识库 到 HTML / 导出 知识库 到 Markdown”。
- 知识库 HTML / Markdown 导出需要重新设计内容结构,不能只复用 Starred 导出模板改标题;但标题、页头、基础排版参考现有 Starred 导出模板,不再单独展开导出视觉细节。知识库导出排序沿用知识库集合排序。
- 知识库 HTML / Markdown 导出默认直接包含用户 notes,不提供额外“是否包含笔记”选项。
- 知识库导出与现有 Starred 导出一致: 有摘要就导出,没有摘要不为导出临时触发 README 拉取、AI 摘要、Health 或 OpenSSF 刷新。
- 知识库为空时,点击“导出 知识库 到 HTML/Markdown”不生成空文件,只给 toast 提示;Starred 导出现有行为不变。
- ShareCard/Profile 的知识库文件导出第一版始终导出全量知识库,不跟随 Smart Collections 当前筛选条件。
- ShareCard/Profile 文件导出命名按范围区分: `starcat-starred-YYYY-MM-DD.html/md` 与 `starcat-library-YYYY-MM-DD.html/md`。
- 命名定稿: Swift `outsideLibrary/inLibrary`,DB `outside_library/in_library`,UI `未入库/已入库`,操作 `加入知识库/移出知识库`。

## 9. 不做范围

第一版不做以下内容:

- 不做 AI 自动把 repo 加入知识库。
- 不做复杂评分模型决定是否入库。
- 不把 GitHub unstar 等同于取消入库。
- 不把 Starcat 入库动作自动同步成 GitHub star。
- 不新增一级导航“知识库”,先放在 Smart Collections 内。
- 不重写全部列表信息架构,先在现有 Manage / 详情页 / Smart Collections 框架内落地。

## 10. 初步结论

本需求拆为四条主线:

1. 数据语义: 新增 Starcat 私有 `libraryState`,与 `is_starred`、`RepoStatus.using` 分离。
2. 入口交互: 详情页动作区新增常驻 ❤️ 知识库按钮,带点击动画。
3. 列表识别: 统一 repo 卡片在 logo 左上角展示已入库 ❤️ 标识。
4. 智能集合: 新增系统集合“知识库”。
5. AI/MCP 边界: AI 索引、语义搜索、上下文与 MCP 同时覆盖 starred 和知识库,GitHub 同步和 Star 操作继续基于 starred。
