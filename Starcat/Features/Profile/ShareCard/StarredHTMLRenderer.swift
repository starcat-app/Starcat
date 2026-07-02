//
//  StarredHTMLRenderer.swift
//  Starcat
//
//  HOM-174：把已 star 的 repo 列表渲染成一份"双击即可离线打开"的单页面 HTML。
//
//  设计目标：
//  - **零外部依赖**：所有 CSS / JS / 字体栈都内联，不挂任何 CDN，确保用户把文件传到任何离线
//    环境（U 盘、内网、飞机上）都能打开。这一点是和"导出 Markdown 然后 reader 渲染"最大的差别。
//  - **现代感**：暗色系主导（GitHub 风格），玻璃质感顶部条 + 卡片网格。第一眼看上去像
//    一个独立产品页面，而不是脚本生成的 boilerplate。
//  - **可用性**：客户端搜索（即输即过滤）+ 按语言/状态/star 数 / 标签排序 + 主题切换。所有交互都
//    在浏览器本地完成，不发任何网络请求。
//  - **英文优先**：所有 UI 文案 / 提示都用英文（comment 里也说明），因为用户明确要求"优先以
//    英文为主"，且这份 HTML 是用来分享/上传的，英文受众更广。
//
//  实现策略：
//  - HTML / CSS / JS 全部以 Swift 多行字符串 + 字符串拼接组装。不引模板引擎，避免新依赖。
//  - 数据通过 `<script type="application/json" id="starred-data">` 嵌入，JS 启动时 parse 并渲染。
//    JSON 编码经过 Foundation `JSONEncoder`，自动处理引号 / 换行 / unicode 转义，安全。
//  - 把 HTML 拆成 head / hero / data / script 几个 builder，避免一个超大字符串读起来失控。
//
//  设计权衡：
//  - 没用 React / Vue：保持 single-file 自包含，不引 npm 生态；JS 量也小（~6KB），原生足够。
//  - 没分页：starred ~1k-5k 量级，浏览器 DOM 直渲也能流畅；遇到 10k+ 再做 virtual scroll。
//  - 头像走 base64 内联（dong4j 2026-06-06 要求）：保持单文件离线打开仍能看到头像；
//    其它仓库 logo 不内联（成百上千张图片会让 HTML 文件膨胀到几十 MB）。
//
//  v2（dong4j 2026-06-06 反馈）：
//  - 每个 repo 卡片在"🏠 Homepage"之后增加 "🪄 AI Summary" 按钮，点击弹模态框，
//    用内联轻量 Markdown 渲染器展示 `RepoAIInsight.summaryMarkdown`。
//  - 新增"Tags"筛选下拉（与 Language / Status 同栏），动态填充用户所有标签。
//  - 用户头像走 base64 data URI 内联，替代之前用 initials 占位的兜底方案。
//  - 修复 toolbar 控件水平不对齐：把 .select 改成水平 row 布局（label 在 select 左），
//    与 .search 输入框同高同基线，告别"label 在上、select 在下"的双行视觉错位。
//

import Foundation

/// 把 [Repo] 渲染为离线可打开的单页面 HTML。无状态。
enum StarredHTMLRenderer {

    /// Starcat 官网地址。导出 HTML 里所有 Starcat 品牌链接都指向官网，不再分散写仓库地址。
    private static let starcatWebsiteURL = "https://starcat.ink"

    /// 导出 HTML 需要的"附加资源"。
    ///
    /// 这些是从 Repo 元数据本身拿不到、必须额外从其它 Repository / 网络拉的数据。
    /// 全部可选，缺省时退化为不显示对应模块（卡片不显示 AI 按钮、Tags 下拉不显示、头像走 initials）。
    ///
    /// 把这些拼成单一结构体而不是给 `render` 加 3 个并列参数：① 减少 call site 噪音；
    /// ② 测试 / Preview 直接传 `.empty` 即可，未来加新字段（如 notes 缓存）只动结构定义不动签名。
    struct ExportSupplements {
        /// 每个 repo 对应的 AI 摘要 Markdown。空 / nil 都视作"该 repo 没有可展示的 AI 摘要"。
        var aiSummaries: [Int64: String]
        /// 每个 repo 对应的标签名数组。空数组视作"未打标签"。
        var repoTags: [Int64: [String]]
        /// 用户头像的 base64 data URI，形如 `data:image/png;base64,iVBORw0...`。
        /// nil 表示下载 / 编码失败，渲染端退化为 initials 占位。
        var avatarDataURI: String?
        /// 按 owner 名索引的 base64 data URI 字典。缺省即不渲染头像位。
        /// HOM-174 v3（dong4j 2026-06-06）：repo 卡片增加 owner 头像作为 logo。
        var ownerAvatars: [String: String]

        static let empty = ExportSupplements(
            aiSummaries: [:],
            repoTags: [:],
            avatarDataURI: nil,
            ownerAvatars: [:]
        )
    }

    /// 主入口。
    /// - Parameters:
    ///   - repos: 已 star 的 repos。
    ///   - user: 当前登录用户。
    ///   - exportedAt: 导出时间戳，注入便于测试。
    ///   - supplements: AI 摘要 / 标签 / 头像等附加数据；测试默认走 `.empty`。
    /// - Returns: 完整 HTML 文档字符串。
    static func render(
        repos: [Repo],
        user: GitHubUserDTO,
        exportedAt: Date = Date(),
        supplements: ExportSupplements = .empty
    ) -> String {
        let dataJSON = encodeData(repos: repos, user: user, exportedAt: exportedAt, supplements: supplements)
        let heroHTML = buildHero(repos: repos, user: user, exportedAt: exportedAt, supplements: supplements)

        return """
        <!DOCTYPE html>
        <html lang="en" data-theme="dark">
        \(buildHead(user: user))
        <body data-theme="dark">
          <div class="app-shell">
            \(heroHTML)
            \(buildToolbar())
            \(buildMain())
            \(buildFooter())
          </div>

          \(buildAISummaryModal())

          \(buildScrollControls())

          <script type="application/json" id="starred-data">\(dataJSON)</script>
          <script>\(buildClientScript())</script>
        </body>
        </html>
        """
    }

    // MARK: - <head>

    private static func buildHead(user: GitHubUserDTO) -> String {
        let displayName = (user.name?.isEmpty == false ? user.name! : user.login)
        let title = "\(htmlEscape(displayName))'s Starred Repositories · Starcat"
        return """
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>\(title)</title>
          <meta name="generator" content="Starcat (\(starcatWebsiteURL))">
          <style>\(buildStylesheet())</style>
        </head>
        """
    }

    // MARK: - Hero header

    private static func buildHero(
        repos: [Repo],
        user: GitHubUserDTO,
        exportedAt: Date,
        supplements: ExportSupplements
    ) -> String {
        let displayName = (user.name?.isEmpty == false ? user.name! : user.login)
        let initials = String(displayName.prefix(2)).uppercased()
        let bio = user.bio?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileURL = user.htmlUrl ?? "https://github.com/\(user.login)"

        // 头像：有 base64 数据走 <img>，否则退化到 initials 文字块。
        // base64 直接内联到 src（data URI）保持单文件离线可打开；不解 SVG / WebP 区别，浏览器统一识别 data: 协议。
        let avatarInner: String = {
            if let dataURI = supplements.avatarDataURI {
                return "<img src=\"\(htmlEscape(dataURI))\" alt=\"\(htmlEscape(displayName))\" loading=\"eager\" decoding=\"async\">"
            } else {
                return "<span>\(htmlEscape(initials))</span>"
            }
        }()

        let totalStars = repos.reduce(0) { $0 + $1.starsCount }
        let langCount = Set(repos.compactMap { $0.language?.htmlNonEmpty }).count

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let exportedISO = dateFormatter.string(from: exportedAt)

        // 个人主页元信息行（条件渲染）
        var profileMeta: [String] = []
        if let location = user.location?.htmlNonEmpty {
            profileMeta.append("<span class=\"meta-pill\">📍 \(htmlEscape(location))</span>")
        }
        if let company = user.company?.htmlNonEmpty {
            profileMeta.append("<span class=\"meta-pill\">🏢 \(htmlEscape(company))</span>")
        }
        if let blog = user.blog?.htmlNonEmpty {
            let url = blog.hasPrefix("http") ? blog : "https://\(blog)"
            profileMeta.append("<a class=\"meta-pill\" href=\"\(htmlEscape(url))\" target=\"_blank\" rel=\"noopener\">🔗 \(htmlEscape(blog))</a>")
        }
        if let email = user.email?.htmlNonEmpty {
            profileMeta.append("<a class=\"meta-pill\" href=\"mailto:\(htmlEscape(email))\">✉️ \(htmlEscape(email))</a>")
        }
        if let twitter = user.twitterUsername?.htmlNonEmpty {
            profileMeta.append("<a class=\"meta-pill\" href=\"https://x.com/\(htmlEscape(twitter))\" target=\"_blank\" rel=\"noopener\">𝕏 @\(htmlEscape(twitter))</a>")
        }
        let metaRowHTML = profileMeta.isEmpty ? "" : """
        <div class="meta-row">\(profileMeta.joined())</div>
        """

        let bioHTML = (bio?.isEmpty == false) ? "<p class=\"hero-bio\">\(htmlEscape(bio!))</p>" : ""

        return """
        <header class="hero">
          <div class="hero-bg"></div>
          <div class="hero-content">
            <div class="hero-identity">
              <a class="avatar\(supplements.avatarDataURI != nil ? " has-image" : "")" href="\(htmlEscape(profileURL))" target="_blank" rel="noopener" aria-label="Open GitHub profile">
                \(avatarInner)
              </a>
              <div class="hero-text">
                <h1 class="hero-name">\(htmlEscape(displayName))</h1>
                <a class="hero-login" href="\(htmlEscape(profileURL))" target="_blank" rel="noopener">@\(htmlEscape(user.login))</a>
                \(bioHTML)
                \(metaRowHTML)
              </div>
            </div>

            <div class="hero-stats">
              <div class="stat-card">
                <span class="stat-value">\(repos.count.htmlFormatted())</span>
                <span class="stat-label">Starred</span>
              </div>
              <div class="stat-card">
                <span class="stat-value">\(totalStars.htmlFormatted())</span>
                <span class="stat-label">Upstream stars</span>
              </div>
              <div class="stat-card">
                <span class="stat-value">\(langCount.htmlFormatted())</span>
                <span class="stat-label">Languages</span>
              </div>
              <div class="stat-card">
                <span class="stat-value">\((user.followers ?? 0).htmlFormatted())</span>
                <span class="stat-label">Followers</span>
              </div>
            </div>

            <p class="hero-meta">
              Exported on <time datetime="\(exportedISO)">\(exportedISO)</time>
              by <a href="\(starcatWebsiteURL)" target="_blank" rel="noopener">Starcat</a>
              — a native macOS app to manage your GitHub stars.
            </p>
          </div>
        </header>
        """
    }

    // MARK: - Toolbar（搜索 + 排序 + 标签 + 主题切换）

    private static func buildToolbar() -> String {
        // 注：所有 <option> 文案、placeholder 都英文，与用户"英文优先"要求一致。
        // v2（dong4j 2026-06-06）：
        // - 新增 Tags 下拉（语言下拉后面），动态由 JS 填充。
        // - 把 .select 的 label 从"上下"改为"水平 row"（CSS 同步改），与 search 输入框同高同基线对齐。
        return """
        <section class="toolbar" aria-label="Filters and controls">
          <div class="toolbar-left">
            <label class="search">
              <span class="search-icon" aria-hidden="true">🔍</span>
              <input id="search-input" type="search" placeholder="Search by name, description, owner, topic…" aria-label="Search repositories">
            </label>
          </div>

          <div class="toolbar-right">
            <label class="select">
              <span class="select-label">Sort</span>
              <select id="sort-select" aria-label="Sort order">
                <option value="starred-desc">Recently starred</option>
                <option value="stars-desc">Most stars</option>
                <option value="pushed-desc">Recently active</option>
                <option value="name-asc">Name (A→Z)</option>
                <option value="created-asc">Oldest project</option>
              </select>
            </label>

            <label class="select">
              <span class="select-label">Language</span>
              <select id="language-select" aria-label="Filter by language">
                <option value="">All</option>
              </select>
            </label>

            <label class="select" id="tag-select-wrapper" hidden>
              <span class="select-label">Tag</span>
              <select id="tag-select" aria-label="Filter by tag">
                <option value="">All</option>
              </select>
            </label>

            <label class="select">
              <span class="select-label">Status</span>
              <select id="status-select" aria-label="Filter by status">
                <option value="">All</option>
                <option value="active">Active (non-archived)</option>
                <option value="archived">Archived</option>
                <option value="fork">Fork</option>
                <option value="non-fork">Original (non-fork)</option>
              </select>
            </label>

            <button id="theme-toggle" type="button" aria-label="Toggle theme">🌓</button>
          </div>
        </section>

        <section class="status-bar" aria-live="polite">
          <span id="result-count">—</span>
        </section>
        """
    }

    // MARK: - AI 摘要模态框（默认隐藏，点击卡片按钮时显示）

    /// 模态框 DOM 一次性写在 body 末尾，JS 端只改填充内容 + display 切换。
    /// 不内嵌在每张卡片里（卡片多达上千张时会复制上千份相同 DOM，浪费体积）。
    private static func buildAISummaryModal() -> String {
        return """
        <div id="ai-modal" class="ai-modal" role="dialog" aria-modal="true" aria-labelledby="ai-modal-title" hidden>
          <div class="ai-modal-backdrop" data-modal-close="1" aria-hidden="true"></div>
          <div class="ai-modal-dialog">
            <header class="ai-modal-head">
              <div class="ai-modal-titles">
                <span class="ai-modal-eyebrow">🪄 AI Summary</span>
                <h2 id="ai-modal-title" class="ai-modal-title">—</h2>
              </div>
              <button type="button" class="ai-modal-close" data-modal-close="1" aria-label="Close">✕</button>
            </header>
            <div id="ai-modal-body" class="ai-modal-body markdown-body">
              <!-- markdown rendered by JS -->
            </div>
          </div>
        </div>
        """
    }

    // MARK: - Main grid placeholder

    private static func buildMain() -> String {
        return """
        <main id="grid" class="repo-grid" aria-live="polite"></main>
        <p id="empty-state" class="empty-state" hidden>No repositories match your filters.</p>
        """
    }

    // MARK: - Footer

    private static func buildFooter() -> String {
        return """
        <footer class="footer">
          Crafted with <a href="\(starcatWebsiteURL)" target="_blank" rel="noopener">Starcat</a>
          · Single-file export · Works fully offline · No tracking
        </footer>
        """
    }

    // MARK: - Scroll controls（HOM-174 v4）

    /// 右下角悬浮的"回到顶部 / 跳到底部"按钮组。
    ///
    /// 设计目的：长列表（500+ 个 repo）下用户向下浏览到中段后，无法快速回到 toolbar 重置过滤；
    /// 同理，从顶部一键直达列表底部也是常见需求。
    ///
    /// 实现要点：
    /// - `position: fixed; right: 24px; bottom: 24px` 永远停留在视窗右下角
    /// - 默认带 `hidden` 属性的"回到顶部"——只在滚动距离 > 400px 时由 JS 显示，避免页面顶部时
    ///   出现冗余按钮
    /// - 按钮 aria-label 完备，键盘可达
    private static func buildScrollControls() -> String {
        return """
        <div class="scroll-controls" aria-label="Page navigation">
          <button id="scroll-top" class="scroll-btn" type="button"
                  aria-label="Scroll to top" title="Scroll to top" hidden>↑</button>
          <button id="scroll-bottom" class="scroll-btn" type="button"
                  aria-label="Scroll to bottom" title="Scroll to bottom">↓</button>
        </div>
        """
    }

    // MARK: - 内嵌数据：JSON 编码

    /// 把 repos + user + supplements 序列化为 JSON 字符串，嵌入 `<script id="starred-data">` 里供 JS 消费。
    /// 用 `JSONEncoder` 而非手拼，自动处理引号/换行/控制字符转义。
    private static func encodeData(
        repos: [Repo],
        user: GitHubUserDTO,
        exportedAt: Date,
        supplements: ExportSupplements
    ) -> String {
        struct Payload: Encodable {
            let user: UserExport
            let exportedAt: String
            let repos: [RepoExport]
            /// 所有标签去重集合，供 toolbar Tags 下拉填充用；按出现频次降序由调用方排好。
            let allTags: [String]
        }
        struct UserExport: Encodable {
            let login: String
            let name: String?
            let htmlUrl: String?
        }
        struct RepoExport: Encodable {
            let id: Int64
            let owner: String
            let name: String
            let fullName: String
            let description: String?
            let language: String?
            let stars: Int
            let forks: Int
            let watchers: Int
            let topics: [String]
            let license: String?
            let homepage: String?
            let htmlUrl: String
            let isArchived: Bool
            let isFork: Bool
            let isPrivate: Bool
            let pushedAt: String?
            let createdAt: String?
            let updatedAt: String?
            let starredAt: String?
            let languageColor: String?

            // v2 新增：每个 repo 关联的用户标签 + AI 摘要 Markdown 文本。
            // 标签与卡片底部"Tags"渲染、Toolbar Tags 过滤共用；空数组视作无标签。
            // AI 摘要 nil/空都视作"无摘要"，UI 端只在非空时显示按钮。
            let tags: [String]
            let aiSummary: String?
            // v3 新增：owner 头像的 base64 data URI；nil 视作"该 owner 头像下载失败 / 未缓存"，
            // 卡片标题左侧退化为占位首字母圆。
            let ownerAvatar: String?
        }

        // 收集 tag → 出现次数，下拉填充按出现频次降序排（与 Language 下拉同套口径，让最常用的排前面）。
        var tagFrequency: [String: Int] = [:]
        for tags in supplements.repoTags.values {
            for name in tags { tagFrequency[name, default: 0] += 1 }
        }

        let exportRepos = repos.map { r -> RepoExport in
            let repoTags = supplements.repoTags[r.id] ?? []
            // summary 可能是空白字符——trim 后判空，避免下拉显示"打开摘要"按钮却弹出空白模态。
            let summary = supplements.aiSummaries[r.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RepoExport(
                id: r.id,
                owner: r.owner,
                name: r.name,
                fullName: r.fullName,
                description: r.description,
                language: r.language,
                stars: r.starsCount,
                forks: r.forksCount,
                watchers: r.watchersCount,
                topics: r.topicsArray,
                license: r.license,
                homepage: r.homepage,
                htmlUrl: r.htmlUrl,
                isArchived: r.isArchived,
                isFork: r.isFork,
                isPrivate: r.isPrivate,
                pushedAt: r.pushedAt,
                createdAt: r.createdAt,
                updatedAt: r.updatedAt,
                starredAt: r.starredAt,
                languageColor: r.language.flatMap { languageHexColor($0) },
                tags: repoTags,
                aiSummary: (summary?.isEmpty == false) ? summary : nil,
                ownerAvatar: supplements.ownerAvatars[r.owner]
            )
        }

        let sortedAllTags = tagFrequency
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { $0.key }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let payload = Payload(
            user: UserExport(login: user.login, name: user.name, htmlUrl: user.htmlUrl),
            exportedAt: dateFormatter.string(from: exportedAt),
            repos: exportRepos,
            allTags: sortedAllTags
        )

        let encoder = JSONEncoder()
        // withoutEscapingSlashes：避免 URL 字段被编码为 `https:\/\/...`，让生成的 JSON 更可读，
        //   也避免误以为出现 `<\/script` 的提前关闭风险（实际不会，但减少阅读心智负担）。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              var str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        // 关键安全转义：JSON 字符串若出现 `</script` 会提前关闭嵌入的 <script> 标签，
        // 导致 XSS / 渲染崩溃（如果用户 repo description 里写了 `</script>`）。
        // 把斜杠转成 unicode 转义；不影响 JSON 解析，浏览器 JSON.parse 仍能识别。
        str = str.replacingOccurrences(of: "</", with: "<\\/")
        return str
    }

    // MARK: - 样式表

    /// 全局 CSS。暗色为默认主题，浅色通过 `<body data-theme="light">` 切换。
    /// 设计参数收口在 `:root` CSS 变量里，主题切换 = 变量重赋值，规避选择器爆炸。
    private static func buildStylesheet() -> String {
        return """
        :root {
          --bg: #0d1117;
          --bg-elevated: #161b22;
          --bg-card: #161b22;
          --bg-card-hover: #1f2630;
          --border: #30363d;
          --border-strong: #484f58;
          --text: #e6edf3;
          --text-dim: #8b949e;
          --text-faint: #6e7681;
          --accent: #58a6ff;
          --accent-glow: rgba(88, 166, 255, 0.25);
          --warn: #f0883e;
          --good: #3fb950;
          --danger: #f85149;
          --topic-bg: rgba(56, 139, 253, 0.12);
          --topic-fg: #79c0ff;
          --hero-gradient: radial-gradient(120% 80% at 0% 0%, rgba(88,166,255,0.18) 0%, transparent 55%),
                           radial-gradient(80% 60% at 100% 0%, rgba(63,185,80,0.12) 0%, transparent 55%),
                           linear-gradient(180deg, #0d1117 0%, #0d1117 100%);
          --card-shadow: 0 1px 0 rgba(255,255,255,0.04) inset, 0 8px 24px rgba(0,0,0,0.35);
          --font-stack: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Inter', 'Helvetica Neue', Arial, sans-serif;
          --mono-stack: ui-monospace, SFMono-Regular, 'JetBrains Mono', 'Menlo', 'Consolas', monospace;
        }

        /* v4 修复（dong4j 2026-06-06）：light 主题选择器必须同时匹配 :root（html）
           才能让 html 元素自身的 --bg 解析到白色。
           原 `body[data-theme="light"]` 单一选择器只覆盖 body 子树，html 元素的
           `background: var(--bg)` 始终拿到 :root 默认 #0d1117（dark），导致页面
           顶部/底部超出 body 高度的部分露出黑条。
           注意：保留 body 选择器是为了让后代选择器（.repo-tag / .ai-modal-backdrop 等）
           能继续按 body[data-theme] 命中——历史代码已写了若干这样的选择器。 */
        :root[data-theme="light"],
        body[data-theme="light"] {
          --bg: #ffffff;
          --bg-elevated: #f6f8fa;
          --bg-card: #ffffff;
          --bg-card-hover: #f6f8fa;
          --border: #d0d7de;
          --border-strong: #afb8c1;
          --text: #1f2328;
          --text-dim: #57606a;
          --text-faint: #6e7781;
          --accent: #0969da;
          --accent-glow: rgba(9, 105, 218, 0.16);
          --warn: #bf8700;
          --good: #1a7f37;
          --danger: #cf222e;
          --topic-bg: rgba(9, 105, 218, 0.10);
          --topic-fg: #0969da;
          --hero-gradient: radial-gradient(120% 80% at 0% 0%, rgba(9,105,218,0.10) 0%, transparent 55%),
                           radial-gradient(80% 60% at 100% 0%, rgba(26,127,55,0.08) 0%, transparent 55%),
                           linear-gradient(180deg, #ffffff 0%, #ffffff 100%);
          --card-shadow: 0 1px 0 rgba(0,0,0,0.02) inset, 0 4px 16px rgba(0,0,0,0.06);
        }

        * { box-sizing: border-box; }

        html, body {
          margin: 0;
          padding: 0;
          background: var(--bg);
          color: var(--text);
          font-family: var(--font-stack);
          -webkit-font-smoothing: antialiased;
          font-size: 14px;
          line-height: 1.55;
        }

        a { color: var(--accent); text-decoration: none; }
        a:hover { text-decoration: underline; }

        .app-shell {
          max-width: 1240px;
          margin: 0 auto;
          padding: 0 32px 64px;
        }

        /* ---------- Hero ---------- */
        .hero {
          position: relative;
          margin: 32px 0 24px;
          padding: 36px 36px 32px;
          border: 1px solid var(--border);
          border-radius: 18px;
          background: var(--hero-gradient);
          overflow: hidden;
        }
        .hero-bg {
          position: absolute; inset: 0;
          pointer-events: none;
          background: radial-gradient(60% 80% at 80% 110%, var(--accent-glow) 0%, transparent 60%);
        }
        .hero-content { position: relative; }

        .hero-identity {
          display: flex; align-items: center; gap: 24px;
          margin-bottom: 28px;
        }
        .avatar {
          width: 88px; height: 88px;
          border-radius: 50%;
          background: linear-gradient(135deg, var(--accent), #3fb950);
          color: white;
          display: flex; align-items: center; justify-content: center;
          font-size: 32px; font-weight: 700;
          letter-spacing: -1px;
          flex: 0 0 auto;
          text-decoration: none;
          overflow: hidden;
          box-shadow: 0 6px 24px var(--accent-glow);
          transition: transform 0.18s ease;
        }
        .avatar:hover { transform: scale(1.04); text-decoration: none; }
        /* 有 base64 头像图时，去掉渐变底色让图片完全填充；img 走 object-fit: cover 不变形。*/
        .avatar.has-image { background: var(--bg-elevated); }
        .avatar img {
          width: 100%; height: 100%; object-fit: cover; display: block;
        }

        .hero-text { min-width: 0; }
        .hero-name {
          margin: 0 0 4px;
          font-size: 26px; line-height: 1.2; font-weight: 700;
          letter-spacing: -0.5px;
        }
        .hero-login {
          font-size: 14px; color: var(--text-dim);
          font-family: var(--mono-stack);
        }
        .hero-bio {
          margin: 12px 0 8px;
          color: var(--text-dim);
          max-width: 720px;
        }
        .meta-row {
          display: flex; flex-wrap: wrap; gap: 8px;
          margin-top: 10px;
        }
        .meta-pill {
          display: inline-flex; align-items: center;
          padding: 4px 10px;
          font-size: 12px;
          background: var(--bg-elevated);
          border: 1px solid var(--border);
          border-radius: 999px;
          color: var(--text-dim);
        }
        .meta-pill:hover { color: var(--text); border-color: var(--border-strong); text-decoration: none; }

        .hero-stats {
          display: grid;
          grid-template-columns: repeat(4, minmax(0, 1fr));
          gap: 12px;
          margin: 8px 0 20px;
        }
        .stat-card {
          display: flex; flex-direction: column; gap: 4px;
          padding: 16px 18px;
          border-radius: 12px;
          border: 1px solid var(--border);
          background: var(--bg-elevated);
        }
        .stat-value {
          font-size: 24px; font-weight: 700; line-height: 1;
          font-variant-numeric: tabular-nums;
          letter-spacing: -0.5px;
        }
        .stat-label {
          font-size: 12px; color: var(--text-dim);
          text-transform: uppercase; letter-spacing: 0.6px;
        }

        .hero-meta {
          margin: 0;
          font-size: 12px; color: var(--text-faint);
        }
        .hero-meta time { font-family: var(--mono-stack); }

        /* ---------- Toolbar ---------- */
        .toolbar {
          display: flex; flex-wrap: wrap; gap: 12px;
          align-items: center; justify-content: space-between;
          padding: 14px 16px;
          margin-bottom: 12px;
          border: 1px solid var(--border);
          border-radius: 12px;
          background: var(--bg-elevated);
          position: sticky; top: 16px; z-index: 10;
          backdrop-filter: saturate(140%) blur(12px);
          -webkit-backdrop-filter: saturate(140%) blur(12px);
        }
        .toolbar-left { flex: 1 1 360px; min-width: 240px; }
        /* align-items: center 让 search / select / button 在同一基线上居中对齐。
           因为 .select v2 已经改为水平 row 内含 label + control，与 .search 高度天然一致。*/
        .toolbar-right { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }

        /* 统一控件高度，让 search / select / theme-toggle 视觉高度一致（dong4j 2026-06-06 反馈"水平不对齐"）。
           36px = 10px padding * 2 + 14px font + 边框 ≈ 一致基线。*/
        .toolbar .search input,
        .toolbar .select select,
        .toolbar #theme-toggle {
          height: 36px;
          box-sizing: border-box;
        }

        .search {
          position: relative; display: flex; align-items: center;
        }
        .search-icon {
          position: absolute; left: 12px;
          font-size: 14px; opacity: 0.7;
          pointer-events: none;
        }
        .search input {
          width: 100%;
          padding: 0 14px 0 36px;
          border-radius: 10px;
          border: 1px solid var(--border);
          background: var(--bg);
          color: var(--text);
          font-size: 14px;
          font-family: inherit;
          outline: none;
          transition: border-color 0.15s ease, box-shadow 0.15s ease;
        }
        .search input::placeholder { color: var(--text-faint); }
        .search input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-glow); }

        /* v2：把 .select 从"垂直 column（label 在上）"改为"水平 row（label 在左）"，
           与 .search 单行输入框形成统一基线，根治"select 上沿伸出 search 上沿"的视觉错位。*/
        .select {
          display: inline-flex; flex-direction: row; align-items: center; gap: 8px;
        }
        .select-label {
          font-size: 11px; color: var(--text-faint);
          text-transform: uppercase; letter-spacing: 0.5px;
          white-space: nowrap;
        }
        .select select {
          padding: 0 28px 0 10px;
          border-radius: 8px;
          border: 1px solid var(--border);
          background-color: var(--bg);
          color: var(--text);
          font-size: 13px;
          font-family: inherit;
          cursor: pointer;
          outline: none;
          appearance: none;
          -webkit-appearance: none;
          /* 自绘 chevron 替代浏览器默认 dropdown 三角，避免 macOS Safari 默认箭头与暗色背景反差差。*/
          background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'><path fill='%238b949e' d='M2.5 4.5 6 8l3.5-3.5z'/></svg>");
          background-repeat: no-repeat;
          background-position: right 8px center;
          background-size: 10px 10px;
        }
        .select select:focus { border-color: var(--accent); }

        #theme-toggle {
          padding: 0 14px;
          border-radius: 8px;
          border: 1px solid var(--border);
          background: var(--bg);
          color: var(--text);
          cursor: pointer; font-size: 14px;
        }
        #theme-toggle:hover { background: var(--bg-card-hover); }

        .status-bar {
          padding: 0 4px 12px;
          font-size: 12px;
          color: var(--text-faint);
        }

        /* ---------- Grid ---------- */
        .repo-grid {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(360px, 1fr));
          gap: 14px;
        }
        @media (max-width: 720px) {
          .repo-grid { grid-template-columns: 1fr; }
          .hero-stats { grid-template-columns: repeat(2, 1fr); }
          .app-shell { padding: 0 20px 48px; }
        }

        .repo-card {
          display: flex; flex-direction: column;
          padding: 18px 18px 16px;
          border-radius: 14px;
          border: 1px solid var(--border);
          background: var(--bg-card);
          box-shadow: var(--card-shadow);
          transition: transform 0.12s ease, border-color 0.15s ease, background 0.15s ease;
        }
        .repo-card:hover {
          border-color: var(--border-strong);
          background: var(--bg-card-hover);
          transform: translateY(-1px);
        }

        .repo-head {
          display: flex; align-items: flex-start; justify-content: space-between;
          gap: 10px;
        }
        /* v3：owner 头像作为 repo logo，放在 head 最左侧 */
        .repo-head-main {
          display: flex; align-items: flex-start; gap: 10px;
          flex: 1; min-width: 0;
        }
        .repo-logo {
          width: 28px; height: 28px;
          border-radius: 6px;
          flex-shrink: 0;
          overflow: hidden;
          background: var(--surface-2);
          display: flex; align-items: center; justify-content: center;
          font-size: 12px; font-weight: 600;
          color: var(--text-dim);
          border: 1px solid var(--border);
          margin-top: 2px; /* 与 16px 标题首行视觉对齐 */
        }
        .repo-logo img {
          width: 100%; height: 100%;
          object-fit: cover;
          display: block;
        }
        .repo-title {
          margin: 0;
          font-size: 16px; font-weight: 600;
          min-width: 0; word-break: break-word;
          line-height: 1.3;
          word-break: break-word;
        }
        .repo-title a { color: var(--text); text-decoration: none; }
        .repo-title a:hover { color: var(--accent); text-decoration: none; }
        .repo-owner { color: var(--text-dim); font-weight: 500; }

        .badges { display: flex; gap: 6px; flex-shrink: 0; }
        .badge {
          font-size: 10px; padding: 2px 6px;
          border-radius: 999px;
          text-transform: uppercase; letter-spacing: 0.5px;
          font-weight: 600;
        }
        .badge.archived { background: rgba(240,136,62,0.16); color: var(--warn); }
        .badge.fork { background: rgba(110,118,129,0.16); color: var(--text-dim); }
        .badge.private { background: rgba(248,81,73,0.16); color: var(--danger); }

        .repo-desc {
          margin: 8px 0 12px;
          font-size: 13px;
          color: var(--text-dim);
          display: -webkit-box;
          -webkit-line-clamp: 3;
          -webkit-box-orient: vertical;
          overflow: hidden;
        }

        .topics {
          display: flex; flex-wrap: wrap; gap: 6px;
          margin-bottom: 12px;
        }
        .topic {
          font-size: 11px; padding: 3px 9px;
          border-radius: 999px;
          background: var(--topic-bg);
          color: var(--topic-fg);
          font-weight: 500;
          cursor: pointer;
          transition: filter 0.12s ease;
        }
        .topic:hover { filter: brightness(1.15); }

        .repo-foot {
          margin-top: auto;
          display: flex; flex-wrap: wrap; gap: 6px 14px;
          font-size: 12px;
          color: var(--text-dim);
          align-items: center;
        }
        .lang-dot {
          display: inline-block;
          width: 10px; height: 10px;
          border-radius: 50%;
          margin-right: 6px;
          background: var(--text-faint);
          vertical-align: middle;
        }
        .foot-item {
          display: inline-flex; align-items: center; gap: 4px;
          font-variant-numeric: tabular-nums;
        }
        .foot-icon { opacity: 0.7; font-size: 11px; }

        .empty-state {
          text-align: center;
          color: var(--text-faint);
          padding: 64px 0;
          font-size: 14px;
        }

        .footer {
          margin-top: 32px;
          padding-top: 24px;
          border-top: 1px solid var(--border);
          text-align: center;
          font-size: 12px;
          color: var(--text-faint);
        }

        /* ---------- Scroll controls（v4：右下角"回到顶部 / 跳到底部"按钮组）---------- */
        .scroll-controls {
          position: fixed;
          right: 24px; bottom: 24px;
          display: flex; flex-direction: column; gap: 8px;
          z-index: 20;
        }
        .scroll-btn {
          width: 40px; height: 40px;
          border-radius: 50%;
          border: 1px solid var(--border);
          background: var(--bg-elevated);
          color: var(--text);
          font-size: 18px; line-height: 1;
          cursor: pointer;
          box-shadow: 0 4px 12px rgba(0,0,0,0.16);
          display: flex; align-items: center; justify-content: center;
          transition: transform 0.15s ease, background 0.15s ease,
                      opacity 0.2s ease, box-shadow 0.15s ease;
          font-family: var(--mono-stack);
        }
        .scroll-btn:hover {
          background: var(--bg-card-hover);
          transform: translateY(-1px);
          box-shadow: 0 6px 16px rgba(0,0,0,0.22);
        }
        .scroll-btn:active { transform: translateY(0); }
        /* hidden 属性 native = display:none —— 滚动距离 < 400px 时"回到顶部"按钮不显示 */
        .scroll-btn[hidden] { display: none; }

        /* ---------- v2：卡片标签 + AI 按钮 ---------- */

        /* 用户标签条：放在 topics 之后；视觉上比 topics 更"内部"，用色块 + tag icon 强调"自定义标签"语义。*/
        .repo-tags {
          display: flex; flex-wrap: wrap; gap: 6px;
          margin: -4px 0 10px;
        }
        .repo-tag {
          display: inline-flex; align-items: center; gap: 4px;
          font-size: 11px; padding: 3px 9px;
          border-radius: 6px;
          background: rgba(163, 113, 247, 0.12);
          color: #d2a8ff;
          border: 1px solid rgba(163, 113, 247, 0.24);
          cursor: pointer;
          transition: filter 0.12s ease;
          font-weight: 500;
        }
        .repo-tag::before {
          content: "🏷";
          font-size: 9px;
          opacity: 0.75;
        }
        .repo-tag:hover { filter: brightness(1.15); }

        body[data-theme="light"] .repo-tag {
          background: rgba(130, 80, 223, 0.10);
          color: #8250df;
          border-color: rgba(130, 80, 223, 0.28);
        }

        /* AI 摘要按钮：放在 foot 区，与 homepage 链接同级；视觉上用 sparkles 色调强调 AI。 */
        .ai-summary-btn {
          display: inline-flex; align-items: center; gap: 4px;
          font-size: 12px;
          padding: 2px 8px;
          border-radius: 999px;
          border: 1px solid rgba(163, 113, 247, 0.35);
          background: linear-gradient(135deg, rgba(163, 113, 247, 0.16), rgba(88, 166, 255, 0.16));
          color: var(--text);
          cursor: pointer;
          font-family: inherit;
          transition: filter 0.12s ease, transform 0.12s ease;
        }
        .ai-summary-btn:hover {
          filter: brightness(1.18);
          transform: translateY(-1px);
        }
        body[data-theme="light"] .ai-summary-btn {
          border-color: rgba(130, 80, 223, 0.40);
          background: linear-gradient(135deg, rgba(130, 80, 223, 0.10), rgba(9, 105, 218, 0.10));
        }

        /* ---------- v2：AI 摘要模态框 ---------- */

        .ai-modal {
          position: fixed; inset: 0;
          z-index: 100;
          display: flex; align-items: center; justify-content: center;
          padding: 32px;
        }
        .ai-modal[hidden] { display: none; }
        .ai-modal-backdrop {
          position: absolute; inset: 0;
          background: rgba(1, 4, 9, 0.65);
          backdrop-filter: blur(4px);
          -webkit-backdrop-filter: blur(4px);
          animation: ai-fade-in 0.18s ease;
        }
        body[data-theme="light"] .ai-modal-backdrop {
          background: rgba(31, 35, 40, 0.36);
        }
        .ai-modal-dialog {
          position: relative;
          max-width: 760px; width: 100%;
          max-height: 80vh;
          display: flex; flex-direction: column;
          background: var(--bg-card);
          border: 1px solid var(--border);
          border-radius: 16px;
          box-shadow: 0 24px 64px rgba(0,0,0,0.45);
          overflow: hidden;
          animation: ai-slide-up 0.22s cubic-bezier(0.22, 1, 0.36, 1);
        }
        .ai-modal-head {
          display: flex; align-items: flex-start; justify-content: space-between;
          gap: 16px;
          padding: 18px 22px 14px;
          border-bottom: 1px solid var(--border);
        }
        .ai-modal-titles { min-width: 0; }
        .ai-modal-eyebrow {
          font-size: 11px;
          color: var(--text-faint);
          text-transform: uppercase;
          letter-spacing: 0.6px;
        }
        .ai-modal-title {
          margin: 4px 0 0;
          font-size: 18px; font-weight: 600;
          color: var(--text);
          word-break: break-word;
        }
        .ai-modal-close {
          flex: 0 0 auto;
          width: 32px; height: 32px;
          border-radius: 8px;
          border: 1px solid var(--border);
          background: var(--bg);
          color: var(--text-dim);
          cursor: pointer;
          font-size: 14px;
          line-height: 1;
        }
        .ai-modal-close:hover {
          background: var(--bg-card-hover);
          color: var(--text);
        }
        .ai-modal-body {
          overflow-y: auto;
          padding: 18px 22px 24px;
          color: var(--text);
          font-size: 14px;
          line-height: 1.65;
        }

        @keyframes ai-fade-in {
          from { opacity: 0; } to { opacity: 1; }
        }
        @keyframes ai-slide-up {
          from { transform: translateY(12px); opacity: 0; }
          to { transform: translateY(0); opacity: 1; }
        }

        /* ---------- v2：轻量 markdown 渲染样式 ---------- */

        .markdown-body h1,
        .markdown-body h2,
        .markdown-body h3,
        .markdown-body h4 {
          margin: 24px 0 12px;
          font-weight: 600;
          line-height: 1.3;
          color: var(--text);
        }
        .markdown-body h1 { font-size: 22px; border-bottom: 1px solid var(--border); padding-bottom: 8px; }
        .markdown-body h2 { font-size: 18px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
        .markdown-body h3 { font-size: 16px; }
        .markdown-body h4 { font-size: 14px; color: var(--text-dim); }
        .markdown-body p { margin: 10px 0; color: var(--text); }
        .markdown-body ul, .markdown-body ol {
          margin: 10px 0; padding-left: 24px;
        }
        .markdown-body li { margin: 4px 0; }
        .markdown-body strong { color: var(--text); font-weight: 600; }
        .markdown-body em { color: var(--text); font-style: italic; }
        .markdown-body code {
          padding: 2px 6px;
          font-family: var(--mono-stack);
          font-size: 0.88em;
          background: var(--bg-elevated);
          border: 1px solid var(--border);
          border-radius: 4px;
          color: var(--accent);
        }
        .markdown-body pre {
          padding: 14px 16px;
          margin: 12px 0;
          background: var(--bg-elevated);
          border: 1px solid var(--border);
          border-radius: 8px;
          overflow-x: auto;
          font-size: 12.5px;
          line-height: 1.55;
        }
        .markdown-body pre code {
          padding: 0;
          border: 0;
          background: transparent;
          color: var(--text);
        }
        .markdown-body a {
          color: var(--accent);
          text-decoration: none;
        }
        .markdown-body a:hover { text-decoration: underline; }
        .markdown-body blockquote {
          margin: 12px 0;
          padding: 4px 14px;
          border-left: 3px solid var(--border-strong);
          color: var(--text-dim);
          background: rgba(110, 118, 129, 0.06);
        }
        .markdown-body hr {
          border: 0;
          border-top: 1px solid var(--border);
          margin: 18px 0;
        }
        .markdown-body table {
          border-collapse: collapse;
          margin: 12px 0;
          font-size: 13px;
        }
        .markdown-body th, .markdown-body td {
          border: 1px solid var(--border);
          padding: 6px 10px;
        }
        .markdown-body th { background: var(--bg-elevated); font-weight: 600; }
        """
    }

    // MARK: - 客户端脚本

    /// 客户端 JS：读 inline JSON → 构建语言/topic/tag 索引 → 注册 input 监听 → 渲染卡片网格。
    /// 整体 ~ 300 行，原生 ES6+，无第三方依赖。包含轻量 markdown 渲染器（支持 GFM 子集）。
    private static func buildClientScript() -> String {
        return """
        (function () {
          'use strict';

          const raw = document.getElementById('starred-data').textContent;
          const data = JSON.parse(raw);
          const repos = Array.isArray(data.repos) ? data.repos : [];
          const allTags = Array.isArray(data.allTags) ? data.allTags : [];

          const grid = document.getElementById('grid');
          const emptyState = document.getElementById('empty-state');
          const resultCount = document.getElementById('result-count');
          const searchInput = document.getElementById('search-input');
          const sortSelect = document.getElementById('sort-select');
          const languageSelect = document.getElementById('language-select');
          const statusSelect = document.getElementById('status-select');
          const tagSelect = document.getElementById('tag-select');
          const tagSelectWrapper = document.getElementById('tag-select-wrapper');
          const themeToggle = document.getElementById('theme-toggle');

          // 主题：默认 dark；持久化到 localStorage（如可用）。
          // v4 修复（dong4j 2026-06-06）：data-theme 必须同时设在 documentElement (html) 和 body 上。
          // 因为 :root[data-theme="light"] 选择器只匹配 html 元素，html 的 --bg 解析必须查到
          // light 变量；只设 body 会让 html 始终用 :root 默认 dark --bg，导致页面顶部/底部露出黑条。
          function applyTheme(theme) {
            document.documentElement.dataset.theme = theme;
            document.body.dataset.theme = theme;
          }
          try {
            const saved = localStorage.getItem('starcat-export-theme');
            if (saved === 'light') applyTheme('light');
            else applyTheme('dark');  // 显式 dark 也走一次，确保两个元素都同步
          } catch (_) { applyTheme('dark'); }
          themeToggle.addEventListener('click', () => {
            const next = document.body.dataset.theme === 'light' ? 'dark' : 'light';
            applyTheme(next);
            try { localStorage.setItem('starcat-export-theme', next); } catch (_) {}
          });

          // v4：右下角"回到顶部 / 跳到底部"按钮。
          // 顶部按钮在滚动 > 400px 时才显示，避免页面顶部冗余；
          // 用 scroll() smooth 走原生平滑滚动，性能比 requestAnimationFrame 手撸更好。
          const scrollTopBtn = document.getElementById('scroll-top');
          const scrollBottomBtn = document.getElementById('scroll-bottom');
          if (scrollTopBtn && scrollBottomBtn) {
            const updateScrollTopVisibility = () => {
              const shouldShow = (window.scrollY || document.documentElement.scrollTop) > 400;
              if (shouldShow) scrollTopBtn.removeAttribute('hidden');
              else scrollTopBtn.setAttribute('hidden', '');
            };
            // 滚动监听 + passive 提示浏览器无需阻塞主线程
            window.addEventListener('scroll', updateScrollTopVisibility, { passive: true });
            updateScrollTopVisibility();

            scrollTopBtn.addEventListener('click', () => {
              window.scrollTo({ top: 0, behavior: 'smooth' });
            });
            scrollBottomBtn.addEventListener('click', () => {
              window.scrollTo({
                top: document.documentElement.scrollHeight,
                behavior: 'smooth'
              });
            });
          }

          // 语言下拉填充
          const langCounts = new Map();
          for (const r of repos) {
            const key = r.language || '(no language)';
            langCounts.set(key, (langCounts.get(key) || 0) + 1);
          }
          const sortedLangs = [...langCounts.entries()].sort((a, b) => b[1] - a[1]);
          for (const [lang, count] of sortedLangs) {
            const opt = document.createElement('option');
            opt.value = lang;
            opt.textContent = lang + ' (' + count + ')';
            languageSelect.appendChild(opt);
          }

          // 标签下拉填充——只有用户至少打过一个标签时才显示下拉，零标签账号不暴露这个控件。
          if (allTags.length > 0) {
            const tagCounts = new Map();
            for (const r of repos) {
              for (const t of (r.tags || [])) tagCounts.set(t, (tagCounts.get(t) || 0) + 1);
            }
            for (const t of allTags) {
              const opt = document.createElement('option');
              opt.value = t;
              opt.textContent = t + (tagCounts.get(t) ? ' (' + tagCounts.get(t) + ')' : '');
              tagSelect.appendChild(opt);
            }
            tagSelectWrapper.hidden = false;
          }

          // 渲染
          function fmt(n) {
            return new Intl.NumberFormat('en-US').format(n);
          }
          function dateOnly(iso) {
            if (!iso) return '—';
            return String(iso).slice(0, 10);
          }
          function el(tag, attrs, children) {
            const node = document.createElement(tag);
            if (attrs) {
              for (const k in attrs) {
                if (k === 'class') node.className = attrs[k];
                else if (k === 'text') node.textContent = attrs[k];
                else node.setAttribute(k, attrs[k]);
              }
            }
            if (children) for (const c of children) if (c) node.appendChild(c);
            return node;
          }

          function renderCard(r) {
            const card = el('article', { class: 'repo-card', 'data-id': String(r.id) });

            const head = el('div', { class: 'repo-head' });
            const headMain = el('div', { class: 'repo-head-main' });

            // v3：owner 头像作为 logo（有 base64 用 img，没有就用首字母占位）
            const logo = el('div', { class: 'repo-logo', title: r.owner });
            if (r.ownerAvatar) {
              const img = el('img', { src: r.ownerAvatar, alt: r.owner, loading: 'lazy' });
              logo.appendChild(img);
            } else {
              logo.appendChild(document.createTextNode(
                (r.owner || '?').slice(0, 1).toUpperCase()
              ));
            }
            headMain.appendChild(logo);

            const titleH = el('h2', { class: 'repo-title' });
            const titleLink = el('a', {
              href: r.htmlUrl,
              target: '_blank',
              rel: 'noopener',
              title: 'Open ' + r.fullName + ' on GitHub'
            });
            titleLink.innerHTML = '<span class="repo-owner">' +
              escapeHTML(r.owner) + '/</span>' + escapeHTML(r.name);
            titleH.appendChild(titleLink);
            headMain.appendChild(titleH);
            head.appendChild(headMain);

            const badges = el('div', { class: 'badges' });
            if (r.isArchived) badges.appendChild(el('span', { class: 'badge archived', text: 'Archived' }));
            if (r.isFork) badges.appendChild(el('span', { class: 'badge fork', text: 'Fork' }));
            if (r.isPrivate) badges.appendChild(el('span', { class: 'badge private', text: 'Private' }));
            if (badges.childNodes.length > 0) head.appendChild(badges);
            card.appendChild(head);

            if (r.description) {
              const desc = el('p', { class: 'repo-desc', text: r.description });
              card.appendChild(desc);
            }

            if (Array.isArray(r.topics) && r.topics.length > 0) {
              const topicsBox = el('div', { class: 'topics' });
              for (const t of r.topics.slice(0, 10)) {
                const tag = el('span', { class: 'topic', text: t, title: 'Filter by ' + t });
                tag.addEventListener('click', () => {
                  searchInput.value = t;
                  apply();
                  searchInput.focus();
                });
                topicsBox.appendChild(tag);
              }
              card.appendChild(topicsBox);
            }

            // 用户标签条（点击 → 跳到 Tag 下拉过滤）
            if (Array.isArray(r.tags) && r.tags.length > 0) {
              const tagsBox = el('div', { class: 'repo-tags' });
              for (const t of r.tags) {
                const tag = el('span', { class: 'repo-tag', text: t, title: 'Filter by tag: ' + t });
                tag.addEventListener('click', () => {
                  tagSelect.value = t;
                  apply();
                });
                tagsBox.appendChild(tag);
              }
              card.appendChild(tagsBox);
            }

            const foot = el('div', { class: 'repo-foot' });
            if (r.language) {
              const langSpan = el('span', { class: 'foot-item' });
              const dot = el('span', { class: 'lang-dot' });
              if (r.languageColor) dot.style.background = r.languageColor;
              langSpan.appendChild(dot);
              langSpan.appendChild(document.createTextNode(r.language));
              foot.appendChild(langSpan);
            }
            foot.appendChild(footItem('★', fmt(r.stars)));
            if (r.forks > 0) foot.appendChild(footItem('⑂', fmt(r.forks)));
            if (r.license) foot.appendChild(footItem('§', r.license));
            if (r.starredAt) foot.appendChild(footItem('Starred', dateOnly(r.starredAt)));
            else if (r.pushedAt) foot.appendChild(footItem('Pushed', dateOnly(r.pushedAt)));
            if (r.homepage) {
              const url = r.homepage.startsWith('http') ? r.homepage : 'https://' + r.homepage;
              const link = el('a', { class: 'foot-item', href: url, target: '_blank', rel: 'noopener' });
              link.appendChild(el('span', { class: 'foot-icon', text: '🏠' }));
              link.appendChild(document.createTextNode(' Homepage'));
              foot.appendChild(link);
            }
            // AI 摘要按钮：仅当该 repo 有缓存摘要时显示（dong4j 2026-06-06 要求放在 Homepage 之后）
            if (r.aiSummary) {
              const aiBtn = el('button', { type: 'button', class: 'ai-summary-btn', 'data-repo-id': String(r.id) });
              aiBtn.textContent = '🪄 AI Summary';
              aiBtn.title = 'Show AI-generated summary for ' + r.fullName;
              aiBtn.addEventListener('click', (e) => {
                e.preventDefault();
                openAISummary(r);
              });
              foot.appendChild(aiBtn);
            }
            card.appendChild(foot);
            return card;
          }
          function footItem(label, value) {
            const span = el('span', { class: 'foot-item' });
            const icon = el('span', { class: 'foot-icon', text: label });
            span.appendChild(icon);
            span.appendChild(document.createTextNode(' ' + value));
            return span;
          }
          function escapeHTML(s) {
            return String(s).replace(/[&<>"']/g, function (c) {
              return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
            });
          }

          function sortRepos(list, mode) {
            const arr = list.slice();
            switch (mode) {
              case 'stars-desc': arr.sort((a, b) => b.stars - a.stars); break;
              case 'pushed-desc': arr.sort((a, b) => String(b.pushedAt || '').localeCompare(String(a.pushedAt || ''))); break;
              case 'name-asc': arr.sort((a, b) => a.fullName.toLowerCase().localeCompare(b.fullName.toLowerCase())); break;
              case 'created-asc': arr.sort((a, b) => String(a.createdAt || '9').localeCompare(String(b.createdAt || '9'))); break;
              case 'starred-desc':
              default: arr.sort((a, b) => String(b.starredAt || '').localeCompare(String(a.starredAt || ''))); break;
            }
            return arr;
          }

          function filterRepos(list, query, language, status, tag) {
            const q = (query || '').trim().toLowerCase();
            return list.filter(r => {
              if (language && r.language !== language && !(language === '(no language)' && !r.language)) return false;
              if (tag && !(Array.isArray(r.tags) && r.tags.indexOf(tag) !== -1)) return false;
              if (status === 'archived' && !r.isArchived) return false;
              if (status === 'active' && r.isArchived) return false;
              if (status === 'fork' && !r.isFork) return false;
              if (status === 'non-fork' && r.isFork) return false;
              if (!q) return true;
              const hay = [
                r.fullName, r.description || '', r.language || '',
                (r.topics || []).join(' '),
                (r.tags || []).join(' '),
                r.license || ''
              ].join(' ').toLowerCase();
              return hay.indexOf(q) !== -1;
            });
          }

          function apply() {
            const filtered = filterRepos(
              repos, searchInput.value,
              languageSelect.value, statusSelect.value, tagSelect.value
            );
            const sorted = sortRepos(filtered, sortSelect.value);
            grid.innerHTML = '';
            const frag = document.createDocumentFragment();
            for (const r of sorted) frag.appendChild(renderCard(r));
            grid.appendChild(frag);

            emptyState.hidden = sorted.length !== 0;
            resultCount.textContent = sorted.length === repos.length
              ? 'Showing all ' + fmt(repos.length) + ' repositories'
              : 'Showing ' + fmt(sorted.length) + ' of ' + fmt(repos.length) + ' repositories';
          }

          let searchTimer;
          searchInput.addEventListener('input', () => {
            clearTimeout(searchTimer);
            searchTimer = setTimeout(apply, 80);
          });
          sortSelect.addEventListener('change', apply);
          languageSelect.addEventListener('change', apply);
          statusSelect.addEventListener('change', apply);
          tagSelect.addEventListener('change', apply);

          // ---------- AI 摘要模态框 ----------

          const modal = document.getElementById('ai-modal');
          const modalTitle = document.getElementById('ai-modal-title');
          const modalBody = document.getElementById('ai-modal-body');

          function openAISummary(r) {
            modalTitle.textContent = r.fullName;
            modalBody.innerHTML = renderMarkdown(r.aiSummary || '');
            modal.hidden = false;
            document.body.style.overflow = 'hidden';
          }
          function closeAISummary() {
            modal.hidden = true;
            modalBody.innerHTML = '';
            document.body.style.overflow = '';
          }
          modal.addEventListener('click', (e) => {
            // 点 backdrop 或关闭按钮（data-modal-close="1"）都关闭；点对话框本体不关。
            const t = e.target;
            if (t && t.getAttribute && t.getAttribute('data-modal-close') === '1') {
              closeAISummary();
            }
          });
          document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && !modal.hidden) closeAISummary();
          });

          // ---------- 轻量 Markdown 渲染器 ----------
          //
          // 支持的子集：ATX 标题 # ## ### #### / 加粗 **xxx** / 斜体 *xxx* / 行内代码 `xxx` /
          //   围栏代码块 ```...``` / 无序列表 - / 有序列表 1. / 链接 [text](url) /
          //   分隔线 --- / 段落 / 自动换行（空行分段）。
          // 不支持：表格 / 图片 / HTML 直注（XSS 防护）/ 嵌套列表深度大于 1 / setext 标题。
          //
          // 安全考量：先对整段 markdown 做 HTML escape，再把已知 markdown 结构反转换为 HTML，
          // 任何用户拼写错误 / 注入尝试都会以 escaped 形式出现，不能形成可执行 HTML。
          function renderMarkdown(md) {
            const lines = String(md || '').split(/\\r?\\n/);
            const out = [];
            let i = 0;
            const n = lines.length;

            function processInline(raw) {
              let s = escapeHTML(raw);
              // 行内代码（先做，避免里面的 * _ 被当成强调）
              s = s.replace(/`([^`\\n]+)`/g, (m, p1) => '<code>' + p1 + '</code>');
              // 加粗
              s = s.replace(/\\*\\*([^*\\n]+)\\*\\*/g, '<strong>$1</strong>');
              // 斜体（避开已是 ** 的情况：用单个 * 包围）
              s = s.replace(/(^|[^*])\\*([^*\\n]+)\\*(?!\\*)/g, '$1<em>$2</em>');
              // 链接 [text](url)
              s = s.replace(/\\[([^\\]]+)\\]\\(([^)\\s]+)\\)/g, (m, text, url) => {
                // url 已 escaped 过；只允许 http/https/mailto，其它走文本兜底防 javascript: 注入。
                if (/^(https?:|mailto:)/i.test(url)) {
                  return '<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + text + '</a>';
                }
                return text;
              });
              return s;
            }

            while (i < n) {
              const line = lines[i];

              // 围栏代码块
              const fence = line.match(/^```(\\w*)\\s*$/);
              if (fence) {
                const lang = fence[1] || '';
                const buf = [];
                i++;
                while (i < n && !/^```\\s*$/.test(lines[i])) {
                  buf.push(lines[i]);
                  i++;
                }
                if (i < n) i++; // skip closing fence
                const codeText = escapeHTML(buf.join('\\n'));
                out.push('<pre><code class="lang-' + escapeHTML(lang) + '">' + codeText + '</code></pre>');
                continue;
              }

              // ATX 标题（1-6 #）
              const heading = line.match(/^(#{1,6})\\s+(.+?)\\s*#*\\s*$/);
              if (heading) {
                const level = Math.min(heading[1].length, 6);
                out.push('<h' + level + '>' + processInline(heading[2]) + '</h' + level + '>');
                i++;
                continue;
              }

              // 分隔线
              if (/^\\s*(---|\\*\\*\\*|___)\\s*$/.test(line)) {
                out.push('<hr>');
                i++;
                continue;
              }

              // 无序列表（连续以 - 或 * 开头的行）
              if (/^\\s*[-*]\\s+/.test(line)) {
                const items = [];
                while (i < n && /^\\s*[-*]\\s+/.test(lines[i])) {
                  const itemText = lines[i].replace(/^\\s*[-*]\\s+/, '');
                  items.push('<li>' + processInline(itemText) + '</li>');
                  i++;
                }
                out.push('<ul>' + items.join('') + '</ul>');
                continue;
              }

              // 有序列表
              if (/^\\s*\\d+\\.\\s+/.test(line)) {
                const items = [];
                while (i < n && /^\\s*\\d+\\.\\s+/.test(lines[i])) {
                  const itemText = lines[i].replace(/^\\s*\\d+\\.\\s+/, '');
                  items.push('<li>' + processInline(itemText) + '</li>');
                  i++;
                }
                out.push('<ol>' + items.join('') + '</ol>');
                continue;
              }

              // 引用 blockquote
              if (/^\\s*>\\s?/.test(line)) {
                const buf = [];
                while (i < n && /^\\s*>\\s?/.test(lines[i])) {
                  buf.push(lines[i].replace(/^\\s*>\\s?/, ''));
                  i++;
                }
                out.push('<blockquote><p>' + processInline(buf.join(' ')) + '</p></blockquote>');
                continue;
              }

              // 空行 → 段落分隔
              if (/^\\s*$/.test(line)) {
                i++;
                continue;
              }

              // 普通段落：连续非空非特殊行合并成一段
              const buf = [line];
              i++;
              while (
                i < n
                && lines[i].trim() !== ''
                && !/^(#{1,6})\\s+/.test(lines[i])
                && !/^\\s*[-*]\\s+/.test(lines[i])
                && !/^\\s*\\d+\\.\\s+/.test(lines[i])
                && !/^\\s*>\\s?/.test(lines[i])
                && !/^```/.test(lines[i])
                && !/^\\s*(---|\\*\\*\\*|___)\\s*$/.test(lines[i])
              ) {
                buf.push(lines[i]);
                i++;
              }
              out.push('<p>' + processInline(buf.join(' ')) + '</p>');
            }

            return out.join('\\n');
          }

          apply();
        })();
        """
    }

    // MARK: - 工具

    /// HTML escape：覆盖 server-side render 拼字符串场景下的所有危险字符。
    private static func htmlEscape(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&#39;")
            default: result.append(ch)
            }
        }
        return result
    }

    /// GitHub Linguist 风格的语言色板（精选 30+ 种主流语言）。未命中返回 nil → JS 端 fallback 灰色。
    /// 色值参考 github/linguist 的 languages.yml；不完整但覆盖 95%+ 主流仓库。
    private static func languageHexColor(_ language: String) -> String? {
        let lower = language.lowercased()
        let map: [String: String] = [
            "swift": "#F05138",
            "objective-c": "#438eff",
            "javascript": "#f1e05a",
            "typescript": "#3178c6",
            "python": "#3572A5",
            "ruby": "#701516",
            "go": "#00ADD8",
            "rust": "#dea584",
            "java": "#b07219",
            "kotlin": "#A97BFF",
            "c": "#555555",
            "c++": "#f34b7d",
            "cpp": "#f34b7d",
            "c#": "#178600",
            "csharp": "#178600",
            "shell": "#89e051",
            "bash": "#89e051",
            "html": "#e34c26",
            "css": "#563d7c",
            "scss": "#c6538c",
            "vue": "#41b883",
            "dart": "#00B4AB",
            "php": "#4F5D95",
            "lua": "#000080",
            "scala": "#c22d40",
            "haskell": "#5e5086",
            "elixir": "#6e4a7e",
            "erlang": "#B83998",
            "perl": "#0298c3",
            "r": "#198CE7",
            "matlab": "#e16737",
            "julia": "#a270ba",
            "clojure": "#db5855",
            "ocaml": "#3be133",
            "fsharp": "#b845fc",
            "f#": "#b845fc",
            "zig": "#ec915c",
            "nim": "#ffc200",
            "crystal": "#000100",
            "dockerfile": "#384d54",
            "makefile": "#427819",
            "vim script": "#199f4b",
            "tex": "#3D6117",
            "powershell": "#012456",
            "groovy": "#e69f56",
            "coffeescript": "#244776",
            "less": "#1d365d",
            "stylus": "#ff6347",
            "jupyter notebook": "#DA5B0B",
            "tsx": "#3178c6",
            "jsx": "#f1e05a"
        ]
        return map[lower]
    }
}

// MARK: - 小工具

private extension String {
    /// 去掉两端空白后非空的字符串；否则 nil。
    /// 与 Markdown renderer 的同名 helper 解耦（fileprivate scope 不互通），避免跨文件意外耦合。
    var htmlNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

private extension Int {
    /// `1234567` → `1,234,567`，HTML hero stats 用。
    ///
    /// **HOM-174 v4 修复（dong4j 2026-06-06）**：
    /// 原实现用 `en_US_POSIX` locale，**POSIX locale 规范上禁用分组分隔符**
    /// （即使手动 `groupingSeparator = ","`），导致 1822 输出仍是 "1822"。
    /// 修复：显式 `usesGroupingSeparator = true` + `groupingSize = 3` 强制启用，
    /// 并改用普通 `en_US` locale（POSIX 是给"不本地化"的场景用的，分组本就该走 en_US）。
    func htmlFormatted() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
