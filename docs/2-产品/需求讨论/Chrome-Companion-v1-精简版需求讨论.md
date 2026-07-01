# Chrome Companion v1 精简版需求讨论

> 状态: 需求收敛讨论
> 日期: 2026-07-01
> 范围: Starcat Chrome 插件第一版能力边界
> 关联:
> - 归档旧方案: `docs/2-产品/需求讨论/_archive/chrome插件-最终方案.md`
> - 正式方案: `docs/2-产品/需求讨论/正式方案/Chrome-Companion-v1-正式方案.md`
> - 详细设计: `docs/3-设计/详细设计/23-Chrome-插件方案.md`
> - 相似推荐: `docs/2-产品/需求讨论/正式方案/相似仓库推荐实施方案.md`
> - Wiki: `docs/3-设计/详细设计/20-wiki-api-对接.md`
> - Repo Health: `docs/2-产品/需求讨论/正式方案/Repo Health 项目健康度方案.md`
> - CodebaseMemory: `docs/2-产品/需求讨论/正式方案/CodebaseMemory集成正式方案.md`

## 1. 背景

旧版 Chrome Companion 方案把插件设计成「浏览器里的 Starcat 小客户端」: 采集到 Inbox、触发 AI 摘要、展示标签/状态/Release、右键追加笔记、浏览器图标角标等能力全部塞进第一版。

这个方向的问题不是不能做, 而是第一版边界过宽:

1. 写入动作太多, 需要很重的鉴权、冲突处理和 UI 状态同步。
2. 与 Starcat App 已有能力重复, 插件会变成另一个需要维护的前端。
3. GitHub 页面 DOM 不稳定, 注入功能越多, 后续维护成本越高。
4. 插件如果直接承担 AI、Health、Wiki、推荐等后端访问, 会打破 Starcat 现有的服务网关与凭证边界。

新的 v1 应该重新定位为:

> GitHub 页面上的 Starcat 上下文增强层, 而不是独立客户端。

插件只做两件事:

1. 在 GitHub repo 页面补充 Starcat 已知的上下文信息。
2. 把需要深度处理的动作交回 Starcat App。

## 2. SimRepo 带来的启发

`Mubelotix/SimRepo` 的产品价值不是复杂交互, 而是在 GitHub repo 页面附近直接展示相似仓库推荐。用户不用离开当前上下文, 就能发现相关项目。

Starcat 已经具备更合适的落地条件:

1. `starcat-recommend-api` 已对接 SimRepo 底层推荐能力。
2. Starcat 客户端已接入 `RecommendAPI`, 并有本地缓存与详情页推荐入口。
3. Starcat 还额外拥有 Wiki、Repo Health、OpenSSF、CodeFlow、CodebaseMemory、私人笔记等本地上下文。

因此 Chrome 插件不需要复刻 SimRepo 的技术实现, 只需要复刻它的「页面上下文增强」产品位置。

## 3. v1 必要功能

### 3.1 相似仓库推荐

在 GitHub repo 页面显示 Starcat 推荐的相似仓库列表。

数据来源:

- 插件不直连 SimRepo。
- 插件不直连 `recommend-api`。
- 插件只请求 Starcat 本机服务, 由 Starcat 复用现有 `RecommendAPI` 与缓存。

第一版只做 repo 页面推荐, 不做 GitHub 首页推荐、star list 推荐、topic 页推荐。

### 3.2 Wiki 按钮

在 GitHub repo 页面显示 Wiki 入口。

数据来源:

- Starcat 已接入 `wiki-api`, 能判断 DeepWiki / Zread / Google Code Wiki 是否收录某 repo。
- 插件从 Starcat 本机服务拿 Wiki links。

第一版只在存在可打开 Wiki 时显示按钮, 不显示「未收录」占位。

### 3.3 私人笔记

在已 star 且 Starcat 本地存在的 repo 页面显示私人笔记。

能力范围:

- 显示当前笔记。
- 新增或修改笔记。
- 保存后直接写入 Starcat 的 `repo_notes.content`。

约束:

- 只对已 star / 已在 Starcat 本地库内的 repo 开放。
- 不为任意陌生 repo 自动建记录。
- 不做富文本, 第一版只做 Markdown/plain text。
- 不做标签、状态、Release 订阅的浏览器内编辑。

### 3.4 Health 与 OpenSSF 分数

在 GitHub repo 页面展示两个轻量指标:

- Starcat Health 分数。
- OpenSSF Scorecard 分数。

数据来源:

- 优先读取 Starcat 本地缓存。
- 缓存缺失时插件只显示「Open in Starcat」或「Analyze in Starcat」入口。
- 不让插件直接请求 OpenSSF。

这样可以避免 GitHub 页面打开时制造大量第三方请求, 也避免把 Health 的刷新策略复制到插件。

### 3.5 CodeFlow 与 Codebase 按钮

在 GitHub repo 页面显示两个入口:

- CodeFlow
- Codebase

点击后由 Starcat App 打开对应能力。

第一版不把 CodeFlow/Codebase 的分析结果嵌入 GitHub 页面, 因为这些能力依赖本地缓存、下载、运行进度、端口、浏览器窗口等复杂状态, 适合留在 App 内。

## 4. 明确不做

v1 不做以下功能:

1. Capture to Inbox。
2. Generate AI Summary。
3. 右键菜单 Append selection。
4. Release unread badge。
5. 标签、状态、Release 订阅的 GitHub 页面内编辑。
6. GitHub 首页推荐。
7. GitHub star list 推荐。
8. 插件直连 GitHub API。
9. 插件直连 Starcat 后端服务。
10. 插件内 AI 对话或摘要。
11. 插件持久化 Starcat 私人数据。

这些功能不是永远不能做, 而是不适合第一版。第一版要先证明「GitHub 页面上下文增强」这个核心价值。

## 5. 产品形态

GitHub repo 页面注入一个 Starcat 面板, 推荐位置是 README 上方或右侧 About 区域附近。

面板信息密度保持克制:

```text
Starcat

Similar
  repo-a        Swift       0.91
  repo-b        TypeScript  0.87
  repo-c        Rust        0.84

Wiki
  DeepWiki  Zread

Notes
  [textarea]
  Save

Signals
  Health 82 B
  OpenSSF 7.4

Actions
  CodeFlow   Codebase   Open in Starcat
```

面板不是卡片堆叠, 而是紧凑工具区。用户在 GitHub 页面阅读 README 时, 不应被 Starcat 抢走主视觉。

## 6. 安全边界

必须遵守以下边界:

1. 插件只保存 Companion Token 与端口。
2. GitHub Token、AI Key、服务 API Key 永远留在 Starcat App。
3. 所有本机接口都必须走 `Authorization: Bearer <companion-token>`。
4. 所有写入动作都必须走本机 HTTP 鉴权接口, 不用无鉴权 `starcat://` 写入。
5. Starcat 本机服务只监听 `127.0.0.1`。
6. 插件只注入 `https://github.com/*`。
7. 插件对 Starcat 私人数据只做短期内存态展示, 不长期缓存。

## 7. 第一版成功标准

1. 打开任意 GitHub repo 页面时, 插件能识别 `owner/repo`。
2. Starcat App 运行并已配对时, 页面能显示推荐、Wiki、笔记、Health/OpenSSF、CodeFlow/Codebase 入口。
3. Starcat App 未运行或未配对时, 页面不报错, 只显示最小提示或完全隐藏。
4. 保存笔记能写回 Starcat, 再打开 Starcat 详情页可见同一内容。
5. 点击 CodeFlow/Codebase 能回到 Starcat App 打开对应能力。
6. 插件不直接访问 GitHub API、SimRepo、recommend-api、wiki-api、OpenSSF 或 AI provider。

## 8. 后续再评估

v1 稳定后再评估:

1. GitHub star list 推荐。
2. GitHub topic 页推荐。
3. 对未 star repo 的临时笔记或采集。
4. 页面内显示 CodeFlow/Codebase 分析摘要。
5. Firefox / Safari 扩展。
