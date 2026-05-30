我会选择你现在这条链路：

**GitHub 服务端渲染 HTML + 本地 ETag 增量缓存 + WKWebView 展示**

而不是客户端 Markdown 解析。

并且在 Starcat 这个场景下，我认为这是**更优解**，甚至比我前面提的“后端自行渲染 Markdown”更适合你当前的产品形态。

------

# **1. 我的选择**

如果让我实现 Starcat 的 README 预览，我会按优先级这样选：

| **方案**                                           | **是否推荐**                   | **适用场景**                                              |
| -------------------------------------------------- | ------------------------------ | --------------------------------------------------------- |
| **GitHub 服务端渲染 HTML + WKWebView + ETag 缓存** | **强烈推荐**                   | Starcat 当前场景：GitHub Trending / repo 详情 / macOS App |
| 客户端 Markdown 解析，例如 cmark-gfm / Down        | 不推荐作为主方案               | 离线阅读、非 GitHub 内容、需要自定义 Markdown 扩展        |
| 自己后端渲染 Markdown 后返回 HTML                  | 可作为 Web 版 / 服务端版本方案 | 多端统一内容服务、服务端聚合、需要 CDN 缓存               |
| 前端 SwiftUI 原生 Markdown 渲染                    | 不推荐                         | 只能处理很简单的 README，GFM 兼容性差                     |

所以结论很明确：

**对于 Starcat 的 macOS 客户端 README 预览，我也会选择你现在这套实现。**

------

# **2. 为什么你现在的方案更适合 Starcat**

## **2.1 README 是 GitHub 内容，交给 GitHub 渲染最合理**

Starcat 展示的是 GitHub 仓库 README，本质上用户期待看到的是：

“和 GitHub 页面上差不多的 README 展示效果。”

那最接近 GitHub 的方式，不是自己模拟 GitHub Markdown，而是直接用：

```http
Accept: application/vnd.github.html
```

让 GitHub 自己返回 HTML。



这个选择非常关键，因为 GitHub README 不只是普通 Markdown，而是 GitHub Flavored Markdown。



它涉及：

```text
- GFM 表格
- task list
- autolink
- emoji
- alert block
- 代码块高亮结构
- 相对链接处理
- 图片代理
- heading anchor
- 部分 HTML 白名单规则
```

如果客户端自己用 `Down` 或 `cmark-gfm` 渲染，后面会不断遇到兼容性问题。



例如：

```markdown
> [!NOTE]
> This is a GitHub alert.
```

或者：

```markdown
- [x] task done
- [ ] task todo
```

再或者 README 里各种 badge、相对图片、HTML 片段，都会变成维护成本。

所以你现在这个选择本质上是：

**把 GFM 兼容性问题外包给 GitHub。**

这是非常正确的工程取舍。

------

# **3. 为什么我不建议客户端 Markdown 解析**

客户端 Markdown 解析看起来很“纯”，但实际会带来很多隐性成本。

## **3.1 GFM 兼容成本高**

如果你用：

```text
cmark-gfm
Down
Ink
swift-markdown
```

你会发现几个问题：

| **问题**                    | **说明**                                   |
| --------------------------- | ------------------------------------------ |
| GitHub alert 不一定完整支持 | `[!NOTE]`、`[!WARNING]` 这种样式需要自己补 |
| 相对链接要自己重写          | README 里的图片和文档链接都要重新 resolve  |
| 图片代理要自己处理          | GitHub 的 camo 逻辑你很难完全复刻          |
| HTML 白名单要自己处理       | README 里允许部分 HTML，但不能全信         |
| 代码高亮要自己接            | 还要处理主题、暗色模式                     |
| CSS 适配成本高              | 最后还是要模拟 GitHub markdown-body        |

最后你会发现：

```text
Markdown Parser
+ GFM Extension
+ HTML Sanitizer
+ Link Rewriter
+ Image Resolver
+ Code Highlighter
+ GFM CSS
+ Dark Mode CSS
```

这一套加起来，复杂度并不低。

------

## **3.2 客户端渲染会浪费性能**

README 是一个典型的“读多写少”内容。

同一个 repo 的 README：

```text
今天可能被打开很多次
但内容一天都不会变
```

如果每次都在客户端重新解析 Markdown，就会浪费 CPU。



而你现在缓存的是：

```text
rendered_html
```

这比缓存 raw markdown 更有价值。



因为真正昂贵的不是下载几 KB Markdown，而是：

```text
解析 Markdown → 生成 HTML → 修正样式 → 渲染展示
```

你现在直接缓存 GitHub 已渲染 HTML，再丢给 WKWebView，路径非常短。

------

## **3.3 第三方依赖越少越好**

Starcat 是 macOS App，README 预览只是 repo 详情页里的一个功能，不是核心业务引擎。

为了这个功能引入：

```text
cmark-gfm
Down
highlighter
HTML sanitizer
```

并不划算。



你现在的依赖边界非常干净：

```text
GitHub API
GRDB
WKWebView
```

没有额外 Markdown 解析依赖，这对 App 体积、稳定性、维护成本都有好处。

------

# **4. 你这套方案里我最认可的几个点**

## **4.1** **`readmes`** **表和** **`repos`** **表分离是对的**

这个设计很好。

README 是大字段，不应该塞进 repo 主表。

否则列表查询的时候，即使你不展示 README，也可能拖出大段文本。

你现在这样：

```text
repos
  - id
  - owner
  - name
  - stars
  - description
  - language
  - ...

readmes
  - repo_id
  - content
  - rendered_html
  - etag
  - last_modified
  - cached_at
  - size
```

是很合理的。

`repos` 负责高频列表查询，`readmes` 负责详情页懒加载。

------

## **4.2 ETag 增量缓存是核心**

你的 `304` 逻辑很关键。

README 这种场景，最适合 HTTP 条件请求：

```http
If-None-Match: xxx
```

如果没变：

```http
304 Not Modified
```

本地继续用旧 HTML。



这样有几个好处：

| **好处**   | **说明**                     |
| ---------- | ---------------------------- |
| 省流量     | 304 没有 body                |
| 省解析     | GitHub 不需要重新返回大 HTML |
| 省写库     | 本地只刷新 cached_at         |
| 用户体验好 | 可以立刻展示缓存             |
| 逻辑标准   | 完全符合 HTTP 缓存语义       |

尤其 Starcat 这种 Trending 客户端，很可能用户每天打开同一批 repo，ETag 能显著减少重复数据传输。

------

## **4.3 304 但本地缓存丢失的兜底非常重要**

你提到这个边缘 case：

本地缓存被清掉但服务端仍返 304 → 去掉 ETag 重拉一次。

这个细节是成熟实现里才会考虑到的。

否则会出现：

```text
本地没有 rendered_html
        |
        v
请求带 If-None-Match
        |
        v
GitHub 返回 304
        |
        v
客户端没有 body 可用
        |
        v
README 白屏 / error
```

你的 `fetchHTMLWithoutValidator` 兜底是必须的。

这个点保留。

------

## **4.4 ViewModel 竞态防护是必要的**

快速切 repo 的场景一定会发生：

```text
点击 A
A 开始加载 README

立刻点击 B
B 开始加载 README

B 先返回
显示 B README

A 后返回
如果不防护，会把 B 页面覆盖成 A README
```

你现在用：

```swift
currentRepoId
currentTask
Task.cancel()
response 回来二次校验 repoId
```

这是正确的。

这一层比缓存还重要，因为这是用户最容易感知到的 bug。

------

## **4.5 WKWebView 链接拦截策略修得对**

你之前踩的白屏坑非常典型。

错误思路是：

```text
默认 cancel 所有导航
只允许部分导航
```

但 `loadHTMLString(_, baseURL:)` 自己就可能触发 `.other` 导航。



所以正确策略应该是你现在这样：

```text
只拦截用户点击 linkActivated
其他导航放行
```

也就是：

```text
linkActivated → 系统浏览器打开，然后 cancel
other → allow
```

这比“全 cancel 再白名单放行”安全且稳定。

------

# **5. 我会保留你的主链路，但会做几个增强**

你的方案主方向不用改。我会在它上面补一些工程增强。

------

## **5.1 增加 stale-while-revalidate 语义**

你现在的链路是：

```text
load repo
  |
  v
find local cache
  |
  v
带 ETag 请求 GitHub
  |
  v
200 / 304 / 404
```

我会稍微调整为：

```text
如果本地有 rendered_html
    |
    v
立即显示本地缓存
    |
    v
后台发 ETag 请求校验
    |
    +-- 304：刷新 cached_at
    +-- 200：更新缓存并刷新 UI
    +-- 失败：继续显示旧缓存
```

这样体验更好。



也就是说，ViewModel 可以区分：

```swift
loaded(readme, isRefreshing: true)
loaded(readme, isRefreshing: false)
```

用户点开详情页时，不需要等网络请求回来。



你现在的实现如果已经是先读本地再校验，那就很好；如果是 `fetchHTML` 整个 await 完才返回，我会建议改成“两阶段返回”。



推荐状态：

```swift
enum ReadmeState {
    case idle
    case loading
    case loaded(Readme, isStale: Bool, isRefreshing: Bool)
    case empty
    case error(Error)
}
```

展示逻辑：

| **场景**               | **UI**                        |
| ---------------------- | ----------------------------- |
| 本地无缓存，网络加载中 | skeleton                      |
| 本地有缓存，后台校验中 | 直接展示 README               |
| 后台校验 304           | 静默结束                      |
| 后台校验 200           | 无感刷新 HTML                 |
| 后台校验失败           | 继续展示旧 README，不打扰用户 |
| 本地无缓存且 404       | empty                         |
| 本地无缓存且失败       | error                         |

这个改动能明显提升体验。

------

## **5.2 给 README 缓存加软过期和硬过期**

目前你有 `cached_at`，我会基于它做两个时间：

```text
softTtl：多久之后需要后台校验
hardTtl：多久之后即使有缓存也认为不可直接信任
```

例如：

```text
softTtl = 6 小时
hardTtl = 7 天
```

逻辑：

```text
cached_at < 6 小时
    直接显示，不请求 GitHub

6 小时 <= cached_at < 7 天
    先显示缓存，后台 ETag 校验

cached_at >= 7 天
    仍可先显示缓存，但 UI 标记 stale，后台必须校验

本地无缓存
    skeleton + 请求 GitHub
```

为什么要 soft TTL？

因为如果每次打开详情都带 ETag 请求，虽然 304 很轻，但仍然会消耗 GitHub API 请求额度。

README 端点也有 rate limit，所以不应该每次都校验。

------

## **5.3 对 404 也缓存**

私有仓库、没有 README、API 权限不足，都会可能返回 404。

如果不缓存 404，用户每次点进去都会请求一次 GitHub。

建议 `readmes` 表里支持状态：

```text
status:
  - success
  - not_found
  - forbidden
  - failed
```

或者新增字段：

```sql
status TEXT NOT NULL DEFAULT 'success'
error_code TEXT
```

对于 404：

```text
缓存 30 分钟 ~ 6 小时
```

这样用户反复进入同一个无 README 仓库，不会不断请求 GitHub。



不过要注意：

```text
404 不能永久缓存
```

因为仓库后面可能新增 README，或者你未来加了 private repo scope 后就能访问了。

------

## **5.4 增加内容大小限制**

GitHub README 有些非常夸张。

建议至少限制：

```text
max_html_size = 2MB 或 5MB
```

超过后可以：

```text
不缓存 rendered_html
显示“README 太大，请在 GitHub 查看”
```

或者：

```text
缓存但不自动加载 WebView，需要用户点击“加载完整 README”
```

这样避免极端仓库拖垮详情页。

------

## **5.5 给 WKWebView 做实例复用或轻量池化**

WKWebView 创建成本不低。

如果 `RepoDetailView` 每次销毁重建 `ReadmeWebView`，可能会有额外开销。

可以考虑：

```text
单详情页复用一个 WKWebView
```

你的 `ReadmeKey(fragment, isDark)` 已经避免重复 `loadHTMLString`，这是对的。



如果后续发现切换 repo 时白屏明显，可以进一步做：

```text
- WebView 容器保持不销毁
- 只更新 document
- skeleton 盖在 WebView 上层
```

但是这个属于优化项，不是第一优先级。

------

# **6. 我不太建议保留** **`content`** **原始 Markdown 字段，除非有明确用途**

你现在表里有：

```text
content = 原始 Markdown，目前未用，留作 P2 翻译 / AI 摘要复用
rendered_html = 实际显示 HTML
```

这里要分情况。



如果你当前请求的是：

```http
Accept: application/vnd.github.html
```

那么拿到的是 HTML，不是 Markdown。



如果想保存原始 Markdown，通常还需要再请求一次：

```http
Accept: application/vnd.github.raw
```

或者使用 `download_url`。

这会多一次网络请求。

所以我建议：

## **当前阶段**

可以只存：

```text
rendered_html
etag
last_modified
cached_at
size
```

`content` 字段可以保留，但先不写入。

## **P2 阶段**

如果确实要做：

```text
README 翻译
README 摘要
README 搜索
README AI 问答
```

那再引入 raw markdown 缓存。



而且那时建议分成两个字段：

```text
raw_markdown
rendered_html
raw_etag
html_etag
```

因为 raw 和 html 的响应可能是不同的表示形式，严格来说 ETag 不一定应该混用。

------

# **7. 我会注意 GitHub API 的媒体类型语义**

你现在用：

```http
Accept: application/vnd.github.html
```

这是对的。



不过实现上我会把 Accept 类型显式建模，不要叫 `getRaw` 时让语义混乱。



因为 `getRaw` 这个名字容易让人误会是 raw markdown，但你实际拿的是 HTML bytes。



我可能会改成：

```swift
func getBytes(
    path: String,
    accept: GitHubMediaType,
    ifNoneMatch: String?,
    ifModifiedSince: String?
) async throws -> GitHubByteResponse
```

或者 README 专用：

```swift
func getReadmeHTML(
    owner: String,
    repo: String,
    ifNoneMatch: String?,
    ifModifiedSince: String?
) async throws -> GitHubReadmeHTMLResponse
```

这样更直观。



命名上避免：

```text
raw = HTML response
```

因为半年后回头看，容易误解。

------

# **8. 我会给** **`assembleDocument`** **加版本号缓存**

你现在有：

```text
ReadmeKey(fragment, isDark)
```

这个避免重复加载很好。



但如果以后 CSS 更新，fragment 没变、isDark 没变，WebView 可能不重新 load。



建议 key 里加：

```swift
cssVersion
```

例如：

```swift
struct ReadmeKey: Equatable {
    let fragmentHash: String
    let isDark: Bool
    let cssVersion: Int
}
```

不要直接把完整 fragment 放进 key 做比较，可以用 hash：

```swift
let fragmentHash = SHA256(fragment)
```

原因：

| **做法**          | **问题**           |
| ----------------- | ------------------ |
| key 里放完整 HTML | 大字符串比较成本高 |
| key 里放 hash     | 比较轻，语义明确   |

这不是必须，但属于干净优化。

------

# **9. 我会把 README 刷新分成两个 API**

现在 `fetchHTML(for:)` 同时承担：

```text
读缓存
校验缓存
请求网络
更新 DB
返回结果
```

逻辑能跑，但后续做 stale-while-revalidate 时，建议拆成两个语义：

```swift
func getCachedReadme(repoId: Int64) async throws -> Readme?
func refreshReadme(for repo: Repo, validator: Validator?) async throws -> ReadmeRefreshResult
```

ViewModel 层就可以这样：

```swift
func load(repo: Repo) {
    currentTask?.cancel()

    currentTask = Task {
        if let cached = try await api.getCachedReadme(repoId: repo.id) {
            state = .loaded(cached, isStale: cached.isStale, isRefreshing: cached.shouldRefresh)
        } else {
            state = .loading
        }

        guard shouldRefresh(cached) else { return }

        do {
            let refreshed = try await api.refreshReadme(for: repo)
            state = .loaded(refreshed, isStale: false, isRefreshing: false)
        } catch NetworkError.notFound {
            if cached == nil {
                state = .empty
            }
        } catch {
            if cached == nil {
                state = .error(error)
            }
        }
    }
}
```

这个结构对用户体验更友好。

------

# **10. 最终我会采用的版本**

如果是我实现 Starcat，我会最终定成这个架构：

```text
RepoDetailView
    |
    v
ReadmeViewModel
    |
    +-- 先读本地 readmes 缓存
    |       |
    |       +-- 有缓存：立即 loaded
    |       +-- 无缓存：loading
    |
    +-- 判断是否需要刷新
            |
            v
        ReadmeAPI.refreshHTML
            |
            v
        GitHub README Endpoint
        Accept: application/vnd.github.html
        If-None-Match: etag
            |
            +-- 200：更新 rendered_html / etag / cached_at，刷新 UI
            +-- 304：touch cached_at，保持 UI
            +-- 404：缓存 not_found，必要时 empty
            +-- error：有旧缓存则静默，无旧缓存才 error
            |
            v
        ReadmeWebView
            |
            v
        assembleDocument(fragment, isDark, cssVersion)
            |
            v
        WKWebView
```

------

# **11. 我对你当前方案的评价**

你的实现方向我会给很高评价。

它的核心优点是：

```text
1. 不自研 GitHub Markdown 渲染
2. 不引入客户端 Markdown 解析器
3. 用 ETag 做标准 HTTP 增量缓存
4. rendered_html 与 repo 元数据分表
5. ViewModel 做了取消和竞态防护
6. WKWebView 关闭 JS，降低攻击面
7. 链接拦截策略已经修正白屏问题
8. ReadmeKey 避免重复 loadHTMLString
```

这不是“简单能用”的实现，而是已经考虑了：

```text
兼容性
性能
缓存
竞态
安全
用户体验
维护成本
```

------

## **我的最终建议**

**不要改主方向。**

你现在这条路线就是我会选的路线。

后续重点不应该换成客户端 Markdown 解析，而应该继续增强这几个点：

```text
1. 先显示本地缓存，再后台 ETag 校验
2. 增加 soft TTL，避免每次打开都请求 GitHub
3. 缓存 404 / notFound 状态，避免重复请求
4. 给大 README 加 size 限制
5. ReadmeKey 改成 fragmentHash + isDark + cssVersion
6. getRaw 命名调整，避免 HTML 响应被叫 raw
7. P2 再考虑 raw markdown 缓存，用于 AI 摘要 / 翻译
```

一句话：



**Starcat 的 README 预览不应该追求“自己解析 Markdown”，而应该追求“尽可能像 GitHub、尽可能快、尽可能少维护”。你现在的方案正好符合这个目标。**

---

# 12. 评审决策（2026-05-30 by AI 协作者 + dong4j）

> **本节是对 5–9 节优化建议的评估、决策与执行计划。**
> 评估原则：Simplicity First / Surgical Changes / 不为想象中的灵活性提前做（详见用户全局规则）。
> 评审日期：2026-05-30 20:00
> 状态：✅ dong4j 已确认按 §12.2「推荐执行顺序」实施。
> 进度：Phase 1 已完成（2026-05-30 20:30）；Phase 2 待 Phase 1 在生产验证 1–2 天无回归后启动。

## 12.1 分级评估

### 第一档：强烈建议做（高 ROI，代码改动小）

#### ⭐ §5.2 软过期 TTL

**为什么做**：当前每次切 repo 都发条件请求，即使刚刚才查过同一个 repo。GitHub README 端点也吃 rate limit（已登录 5000/h 分给所有 endpoint）。

**实现要点**：
- `ReadmeAPI.fetchHTML` 开头加 `if existing != nil && now - cached_at < softTtl { return existing }` 短路
- 不需要 schema migration，`cached_at` 已存在
- softTtl = 6h（MVP 硬编码；Settings 面板留到 P2）
- **"刷新"按钮必须能绕过 softTtl**：API 加 `forceRefresh: Bool = false` 参数

**预估**：~10 行代码 + 2 个单测。

#### ⭐ §5.1 + §9 打包做：SWR + API 拆分

**为什么打包**：单做 §9 只是改名；单做 §5.1 又不优雅。一起改才有结构红利。

**实现要点**：
- `ReadmeAPI.cachedReadme(repoId:)` — 纯读本地，不发网络
- `ReadmeAPI.refreshReadme(for:forceRefresh:)` — 走网络 + 写库，返回 `ReadmeRefreshResult` enum（`.updated / .notModified / .notFound / .failed`）
- `ReadmeViewModel.load(repo:)` 改为 **「先读缓存立即 loaded → 判断 softTtl → 后台 fire-and-forget refresh」** 两段式
- **关键保守设计**：`isRefreshing` 状态**先不暴露给 UI**。已显示的 README 被无感替换在用户视角就是"自动更新了"，符合预期。等用户反馈"我想看到正在刷新"再加。

**预估**：~150 行（含单测改动），结构红利可直接消化 §5.2 / §5.3 的所有衍生需求。

---

### 第二档：做但用轻量版（避免过度工程）

#### §5.3 缓存 404 — **不入库，做 per-session 内存缓存**

**为什么不入库**：原文档建议加 `status TEXT` + `error_code TEXT` 字段 + schema migration v2 = 杀鸡用牛刀。

**实际场景**：用户重复点同一个无 README 的 repo，session 内不再次请求就够了。app 冷启动重新试一次没坏处（可能 README 刚被作者补上）。

**实现要点**：
- `ReadmeViewModel` 加 `private var sessionNotFound: Set<Int64> = []`
- `load(repo:)` 开头：若 `sessionNotFound.contains(repo.id)`，直接 `state = .empty` 不调 API
- 404 catch 时塞进 Set

**预估**：3 行代码。不动 schema、不动 `Readme.swift`、不动单测。

#### §7 `getRaw` → `getBytes` 重命名 — **顺带做**

**为什么做**：`getRaw` 在 GitHub 语境里（`Accept: vnd.github.raw` = 原始 markdown）容易误解。实际语义是"不解码 JSON 的裸字节响应"。

**实现要点**：
- `getRaw` → `getBytes`
- `RawAPIResponse` → `BytesResponse`
- 全局重命名，2 个调用点（`ReadmeAPI.fetchHTML` / `fetchHTMLWithoutValidator`）
- **配合 Phase 2 一起做**，不单独开 PR

---

### 第三档：不做（收益微弱 / 违反 Simplicity First）

| § | 建议 | 不做的理由 |
|---|---|---|
| §5.4 | 大 README size 限制 | GitHub 服务端已有 size limit（~1MB）；当前无性能问题；典型的 speculative feature。**折中**：仅加 `AppLog.network.warning` 当 size > 2MB，有数据再决策 |
| §5.5 | WKWebView 实例池化 | 原文档对 SwiftUI 复用机制有误解：`NSViewRepresentable.updateNSView` 路径下 WebView 是复用的（这正是 `ReadmeKey` 缓存能生效的前提）。真正 makeNSView 重建的场景一个 session 几次而已 |
| §6 | 删除 `content` 字段 | 当前 `content TEXT NULL` 不写入，占用 = 0；删了 P2 翻译/AI 摘要又要加回来 = 两次 migration。**未删的代价 ≪ 删了再加的代价** |
| §8 | `cssVersion` + `fragmentHash` | ① CSS 是编译时静态字符串，app 升级必重启，WebView 全部重建，key 不跨版本复用 → 防御不存在的威胁。② SHA256 哈希反而引入每次 update 都算几百 KB 文本的开销 → 纯亏。Swift `String ==` 在长度不等时立即返回 false，已经够快 |

---

## 12.2 推荐执行顺序

| Phase | 内容 | 预估改动量 | 价值 |
|---|---|---|---|
| **Phase 1** | softTtl(§5.2) + 404 session 缓存(§5.3 轻量版) | ~50 行，改 ReadmeAPI + ReadmeViewModel + 2-3 个新单测 | 立竿见影降低 90% 重复 API 请求 |
| **Phase 2** | SWR + API 拆分(§5.1 + §9) + `getRaw → getBytes` 重命名(§7) | ~150 行，涉及 ReadmeAPI / ReadmeViewModel / 单测 | 体验提升 + 结构清晰，为未来 background sync 铺路 |
| (后续) | §5.4 / §5.5 / §6 / §8 | — | 不做，等遇到具体问题再说 |

**为什么 Phase 1 / Phase 2 拆开**：Phase 1 ROI 最高且改动小，应当独立验证；Phase 2 是结构性改动，需要更仔细的 review，单独评估。

---

## 12.3 对原文档的两点订正

> 以下两点是评审过程中发现原 §5.5 / §8 的论证不准确，记入文档作为团队记录，避免未来基于错误前提再决策。

### 订正 1：§5.5 WKWebView 池化的前提有误

原文档说"如果 `RepoDetailView` 每次销毁重建 `ReadmeWebView`，可能会有额外开销"——但 SwiftUI 的 `NSViewRepresentable` 在 view tree 稳定时**只调用 `updateNSView` 不调用 `makeNSView`**，WKWebView 实例是复用的。我们的 `ReadmeKey` 缓存能正常工作恰好证明了这点（如果 WebView 每次都新建，`Coordinator.lastLoadedKey` 永远是 nil，根本起不到避免白闪的作用）。

真正会触发 `makeNSView` 重建的场景：`RepoDetailView` 从 `nil`（empty state）→ `repo`（详情态）的过渡，这种切换一个 session 也就几次，优化收益 ≈ 0。

### 订正 2：§8 `cssVersion` 防御的是不存在的威胁

原文档说"如果以后 CSS 更新，fragment 没变、isDark 没变，WebView 可能不重新 load"——但：
- CSS 是 Swift 源码里的 `static let css: String`，更新 = app 升级 = 进程重启
- 进程重启 → WKWebView 全部销毁重建 → `Coordinator.lastLoadedKey` 是新 nil
- 不存在"app 运行期 CSS 变更但 ReadmeKey 没变"的物理可能

`cssVersion` 字段挡的是不存在的威胁，纯属过度工程。如果未来真要做主题切换（多套 CSS），那时再加 `themeId`，且必须是运行时可变的状态才有意义。

---

# 13. TODO List（待 dong4j 二次确认后启动）

> 每条 TODO 标注：**修改文件 / 操作 / 验证方式**。
> 完成后必须勾选 `[x]` + 在 `docs/工程进度/功能实现总览.md` 加 `> 实现：...` 行 + 变更日志加一行（详见 CLAUDE.md / AGENTS.md 工作流约定）。

## Phase 1：softTtl + 404 session 缓存（预估 ~50 行）

**✅ Phase 1 已完成（2026-05-30 20:30）**。实际改动 2 文件 + 新增 1 测试文件 + `.pbxproj` 注册；新增 5 项单测；47 → 52 项全绿。

### 任务清单

- [x] **T1.1** `Starcat/Core/Network/GitHubAPI/ReadmeAPI.swift`：新增 `static let softTtl: TimeInterval = 6 * 3600`（注释说明：6h 内同一 repo 不再发条件请求；用户手动刷新可绕过）。
- [x] **T1.2** `ReadmeAPI.swift`：`fetchHTML(for:)` 方法签名改为 `fetchHTML(for repo: Repo, forceRefresh: Bool = false) async throws -> Readme`。
- [x] **T1.3** `ReadmeAPI.swift`：在 `existing = try await repository.find(...)` 之后立即加 softTtl 短路：
  ```
  若 forceRefresh == false && existing 不为 nil
    && existing.cachedAt 在 softTtl 内
    && existing.renderedHtml 非空
  → 直接 return existing，不发网络
  ```
  注意 `cachedAt` 是 ISO8601 字符串，已提取 `static func isWithinSoftTtl(cachedAt:now:softTtl:)` 解析比较。
- [x] **T1.4** `Starcat/Features/Home/ReadmeViewModel.swift`：新增 `private var sessionNotFound: Set<Int64> = []`。
- [x] **T1.5** `ReadmeViewModel.swift`：load 路径合并为 `loadInternal(repo:forceRefresh:)`；自动加载分支（forceRefresh=false）开头检查 sessionNotFound → 直接 `.empty`。
- [x] **T1.6** `ReadmeViewModel.swift`：`loadInternal` 的 `catch NetworkError.notFound` 分支追加 `self.sessionNotFound.insert(requestedId)`。
- [x] **T1.7** `ReadmeViewModel.swift`：`reload(repo:)` 调用 `loadInternal(repo:, forceRefresh: true)`；forceRefresh 路径开头 `sessionNotFound.remove(repo.id)`（给一次重试机会）。
- [x] **T1.8** `StarcatTests/ReadmeAPITTLTests.swift`：新建文件，覆盖 5 个纯函数 case（within / expired / boundary / invalid string / clock drift）。**未做"是否真的没调 client"的网络路径测试**——`GitHubAPIClient` 是 concrete actor 无协议抽象，要等 D-14 URLProtocol stub 落地后一起补。
- [x] **T1.9** 编译 + 全量单测全绿：`TEST SUCCEEDED`，52 tests in 11 suites（新增 1 个 Suite "ReadmeAPI softTtl 短路"，5 项）。
- [ ] **T1.10**（**由 dong4j 在 app 内手动验证**）：连续切 3 次同一个 repo → Console 应只看到 1 次 `GET-raw /repos/.../readme` 网络日志（之前是 3 次）；点底栏"刷新"按钮 → 应能看到一次 `GET-raw` + ETag 校验日志。
- [x] **T1.11** 更新 `docs/工程进度/功能实现总览.md`：3.3 节追加 `[x] README 缓存软过期 + 404 session 缓存` + 实现说明；顶部「最近更新」+「变更日志」+ 仪表盘（33 → 34，47 → 52）。

### 已知风险与约束

- **风险 R1.1**：`sessionNotFound` 在 ViewModel 销毁后丢失。若用户在设置里"清空缓存"或冷启动，404 会重新请求一次——可接受（README 也许被作者补上）。
- **约束 C1.1**：softTtl 暂不暴露到 Settings，硬编码 6h。Settings 面板在 P2 接入。
- **约束 C1.2**：ReadmeAPI 单测仍依赖 mock；URLProtocol stub（D-14）不在本期范围。
- **新增约束 C1.3**（落地后追加）：`sessionNotFound` 行为与 softTtl 短路真实生效路径都未在自动化测试中验证，全靠 T1.10 手动验证 + 代码 review 兜底。Phase 2 在引入 API 拆分时若顺便引入轻量协议抽象，可一并补完整。

---

## Phase 2：SWR + API 拆分 + 重命名（预估 ~150 行）

> ⚠️ **触发条件**：Phase 1 上线 + 验证 1-2 天无回归后再启动。两期不要混在一个 PR 里。

### 任务清单

- [ ] **T2.1** `Starcat/Core/Network/GitHubAPI/GitHubAPIClient.swift`：`getRaw` → `getBytes`；`RawAPIResponse` → `BytesResponse`；全局重命名（搜 `getRaw` / `RawAPIResponse` 全部替换，注释也跟着改）。
- [ ] **T2.2** `Starcat/Core/Network/GitHubAPI/ReadmeAPI.swift`：新增 enum `ReadmeRefreshResult`：
  ```swift
  enum ReadmeRefreshResult {
      case updated(Readme)       // 200，已写入本地
      case notModified(Readme)   // 304，本地 cached_at 已 touch
      case notFound              // 404
      case failed(Error)         // 网络 / 解析错误，未抛出
  }
  ```
- [ ] **T2.3** `ReadmeAPI.swift`：拆 `fetchHTML` 为两个方法：
  - `func cachedReadme(repoId: Int64) async throws -> Readme?` — 纯读本地，等价于直接调 `repository.find(...)`
  - `func refreshReadme(for repo: Repo, forceRefresh: Bool = false) async -> ReadmeRefreshResult` — 注意签名是 `async` 不 throws，所有错误包到 `.failed(error)`
- [ ] **T2.4** `ReadmeAPI.swift`：删除旧 `fetchHTML(for:)`（无调用方了），删除 `fetchHTMLWithoutValidator`（合并进 refreshReadme 内部）。
- [ ] **T2.5** `Starcat/Features/Home/ReadmeViewModel.swift`：重写 `load(repo:)` 为两段式：
  ```
  1. cachedReadme(repoId:) 同步读
     - 有 cached 且 renderedHtml 非空 → 立即 state = .loaded
     - 无 cached → state = .loading
     - 是 sessionNotFound → state = .empty + return
  2. 判断是否需要后台刷新
     - 有 cached 且 cachedAt 在 softTtl 内 → 跳过
     - 否则 → currentTask = Task { 调 refreshReadme → 按结果更新 state }
  ```
  - `isRefreshing` 状态**不暴露**给 UI（保持当前 5 态枚举不变）
- [ ] **T2.6** `ReadmeViewModel.swift`：refreshReadme 返回 `.failed` 时，**只有 cached 不存在才转 .error**；有 cached 就静默保持 .loaded（按 §5.1 表格规则）。
- [ ] **T2.7** `Starcat/App/AppDependencies.swift`：检查 ReadmeAPI 注入是否需要调整（不应该需要，但确认一下）。
- [ ] **T2.8** 单测：
  - 已有 `ReadmeRepositoryTests` 5 项保持不变（Repository 层未改）
  - 新增 ReadmeAPI 层 mock 单测（与 T1.8 共用 mock client），覆盖 cachedReadme / refreshReadme 各分支
- [ ] **T2.9** 编译 + 全量单测全绿。
- [ ] **T2.10** 手动验证：
  - 切 repo（无缓存）→ skeleton → 加载完成
  - 切回之前看过的 repo（cached_at < 6h）→ 立即显示，无网络请求
  - 切到 cached_at > 6h 的 repo → 立即显示旧 HTML + Console 看到后台 refresh 日志 → 新 HTML 无感替换
  - 后台 refresh 失败（断网模拟）→ 旧 HTML 仍显示，不弹错误
- [ ] **T2.11** 更新 `docs/工程进度/功能实现总览.md`：
  - 3.3 节新增 `- [x] README SWR + API 拆分` 条目 + `> 实现：...` 行
  - 顶部「最近更新」刷新
  - 「变更日志」追加一行

### 已知风险与约束

- **风险 R2.1**：API 拆分是结构性改动，没有 URLProtocol stub 时单测靠 mock 拼，覆盖率比 Repository 层低。**缓解**：T2.10 的手动验证 4 个场景必须全过。
- **风险 R2.2**：`refreshReadme` 改为 `async` 不 throws 后，调用方处理逻辑变化大；建议先小范围 review 再合并。
- **约束 C2.1**：UI 层不引入 `isRefreshing` 显示，保持 5 态状态机。若未来用户反馈"想看到正在刷新"，再加。

---

## 13.1 跨 Phase 共用工作

- [ ] **TX.1** Phase 1 / Phase 2 各自的代码评审 — 由 dong4j 在 PR 阶段把关。
- [ ] **TX.2** Phase 2 合并后，在 `docs/详细设计/readme.md-渲染设计.md` §10「最终我会采用的版本」对照实际实现做一次校对（确认架构图与代码一致），不一致处更新文档。
- [ ] **TX.3** 把 §12.3 两点订正同步告知原文档作者（如果是外部评审），避免对方在其他项目里基于同样的误解再做决策。

---

*评审 + TODO 编排完成时间：2026-05-30 20:00。等待 dong4j 二次确认后启动 Phase 1。*