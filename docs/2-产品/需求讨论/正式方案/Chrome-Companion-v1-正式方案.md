# Chrome Companion v1 正式方案

> 状态: 已确认方向, 待实现
> 日期: 2026-07-01
> 范围: Chrome Companion v1 产品方案
> 详细设计: `docs/3-设计/详细设计/23-Chrome-插件方案.md`

## 1. 一句话定位

> Chrome Companion v1 是 GitHub repo 页上的 Starcat 上下文增强层。

它不承担 Starcat 的完整功能, 不做采集收件箱, 不做 AI 摘要, 不做复杂右键菜单。第一版只把 Starcat 已经拥有的五类 repo 上下文放到 GitHub 页面上:

1. 相似仓库推荐。
2. Wiki 入口。
3. 私人笔记。
4. Health / OpenSSF 分数。
5. CodeFlow / Codebase 入口。

## 2. 用户价值

用户在 GitHub 页面阅读 README 时, 往往需要回答几个问题:

1. 有没有相似项目可比较?
2. 这个项目有没有外部 Wiki 可以快速读?
3. 我之前是否写过私人笔记?
4. 这个项目维护和安全状态如何?
5. 能不能直接进入 Starcat 的代码分析能力?

这些信息 Starcat 已经具备, 但它们目前只在 App 内。Chrome Companion v1 的价值是把这些上下文投射到 GitHub 页面, 降低用户切换成本。

## 3. 功能清单

### F1 相似仓库推荐

在 GitHub repo 页面展示最多 5 条相似仓库。

展示字段:

- `full_name`
- `language`
- `stars`
- `score`
- `reason` 首条

点击行为:

- 默认打开 GitHub 页面。
- 如果 Starcat 本机服务返回该推荐项已在本地库中, 后续版本可改为打开 Starcat 详情页。

约束:

- 插件不直连 SimRepo。
- 插件不直连 `recommend-api`。
- 推荐为空时隐藏该分组。

### F2 Wiki 按钮

展示 Starcat 已知的 Wiki links。

展示来源:

- DeepWiki
- Zread
- Google Code Wiki

点击行为:

- 直接打开对应外部 Wiki URL。

约束:

- 只展示 `indexed` 的来源。
- 不展示错误状态。
- 不展示未收录占位。

### F3 私人笔记

对 Starcat 已知且已 star 的 repo 显示笔记编辑区。

能力:

- 加载当前笔记。
- 编辑笔记。
- 保存笔记。

保存语义:

- 覆盖 `repo_notes.content`。
- 保留已有 `repo_notes.status`。
- 保存成功后更新页面上的保存状态。

限制:

- 第一版不支持 Markdown 预览。
- 第一版不支持笔记历史。
- 第一版不支持未 star repo 笔记。

### F4 Health / OpenSSF 分数

展示两个 badge:

- Starcat Health: `overallScore` + `grade`
- OpenSSF: `aggregateScore`

数据策略:

- 优先读 Starcat 本地缓存。
- 缓存缺失时显示轻量占位, 不在插件里触发第三方请求。
- 用户需要刷新时点击 `Open in Starcat` 进入 App。

### F5 CodeFlow / Codebase 入口

展示两个按钮:

- CodeFlow
- Codebase

点击行为:

- 调用 Starcat 本机 action 接口。
- Starcat App 激活并打开对应面板或窗口。

约束:

- 插件不显示分析进度。
- 插件不嵌入 CodeFlow HTML。
- 插件不启动本地 CodebaseMemory UI。

## 4. 插件页面形态

### 4.1 注入范围

只匹配:

```text
https://github.com/{owner}/{repo}
https://github.com/{owner}/{repo}/...
```

排除:

```text
github.com/settings
github.com/marketplace
github.com/orgs
github.com/topics
github.com/trending
github.com/pulls
github.com/issues
```

其中 `pulls` / `issues` 顶级页面不是 repo 页面; repo 内的 `/owner/repo/issues` 和 `/owner/repo/pulls` 仍可识别。

### 4.2 面板位置

优先插入到 README 上方。如果当前页面没有 README, 插入到 repo header 下方。找不到稳定容器时不注入。

### 4.3 视觉原则

1. 面板紧凑, 不抢 GitHub 主内容视觉。
2. 每个分组可独立隐藏。
3. 空数据不显示占位。
4. 错误状态只显示最小连接提示。
5. 所有文案用英文, 因为插件运行在 GitHub 页面中, 避免跟 Starcat App locale 产生混合。

## 5. Starcat 与插件职责

| 能力 | Chrome 插件 | Starcat App |
|---|---|---|
| 解析当前 repo | 负责 | 校验 |
| 推荐数据 | 渲染 | 调 `RecommendAPI` / 读缓存 |
| Wiki links | 渲染 | 调 `WikiAPI` / 读结果 |
| 私人笔记 | 展示与编辑 | 读写 `RepoNoteRepository` |
| Health | 渲染 badge | 读 `RepoHealthService` 缓存 |
| OpenSSF | 渲染 badge | 读 `OpenSSFScoreRepository` 缓存 |
| CodeFlow | 发 action | 打开 App 内能力 |
| Codebase | 发 action | 打开 App 内能力 |
| GitHub Token | 不接触 | 持有 |
| AI Key | 不接触 | 持有 |
| 服务 API Key | 不接触 | 持有 |

## 6. 本机服务约定

插件只与 Starcat 本机服务通信:

```text
http://127.0.0.1:{port}/local/v1/...
```

所有接口必须带:

```text
Authorization: Bearer <companion-token>
```

本机服务只允许:

- `Origin: chrome-extension://...`
- 无 Origin 的本机请求

不允许网页任意 Origin 读取 Starcat 私人数据。

## 7. 配对流程

第一版使用手动配对:

1. Starcat Settings 显示端口和 Companion Token。
2. 用户安装 Chrome 插件。
3. 用户在插件 Options 中填入端口和 token。
4. 插件点击 Test Connection 调 `/local/v1/ping`。
5. 成功后开始在 GitHub 页面注入 Starcat 面板。

暂不做自动发现、二维码配对、Native Messaging。

## 8. 不做项

v1 明确不做:

1. Inbox / Capture。
2. AI Summary 触发。
3. Release unread badge。
4. 标签编辑。
5. 状态编辑。
6. Release 订阅编辑。
7. 右键菜单。
8. GitHub 首页推荐。
9. star list 推荐。
10. 插件内登录 Starcat。

## 9. 验收标准

### 9.1 功能验收

1. GitHub repo 页面能正确识别 `owner/repo`。
2. Starcat 已运行且已配对时, 面板能展示 Starcat 返回的可用分组。
3. 推荐为空时不显示推荐分组。
4. Wiki 为空时不显示 Wiki 分组。
5. 未 star repo 不显示笔记编辑区。
6. 已 star repo 保存笔记后, Starcat App 详情页能看到同一笔记。
7. Health/OpenSSF 缓存存在时能显示分数。
8. CodeFlow/Codebase 按钮能激活 Starcat App。

### 9.2 安全验收

1. 插件源码中不存在 GitHub Token / AI Key / 服务 API Key。
2. 插件不请求 `api.github.com`。
3. 插件不请求 Starcat 后端服务域名。
4. 未带 Bearer token 的本机请求返回 401。
5. 非 Chrome extension Origin 的请求返回 403。
6. 重复 query/header 不导致 Starcat 崩溃。

### 9.3 降级验收

1. Starcat 未运行时 GitHub 页面不报错。
2. token 错误时显示最小连接失败状态。
3. 本机服务返回部分字段为空时, 对应分组隐藏, 其他分组照常显示。

## 10. 后续版本候选

v1 稳定后再评估:

1. 未 star repo 临时笔记。
2. Capture to Starcat。
3. GitHub star list 推荐。
4. GitHub topic 页推荐。
5. 页面内 CodeFlow/Codebase 摘要预览。
6. Safari extension。
