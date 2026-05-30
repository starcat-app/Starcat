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