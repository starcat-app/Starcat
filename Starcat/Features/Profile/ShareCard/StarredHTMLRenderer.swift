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
//  - **可用性**：客户端搜索（即输即过滤）+ 按语言/状态/star 数排序 + 主题切换。所有交互都
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
//  - 没用 React / Vue：保持 single-file 自包含，不引 npm 生态；JS 量也小（~3KB），原生足够。
//  - 没分页：starred ~1k-5k 量级，浏览器 DOM 直渲也能流畅；遇到 10k+ 再做 virtual scroll。
//  - 没存图（avatar / repo 截图）：避免文件体积爆炸 + 离线打开找不到图；用文字 + 配色块替代。
//

import Foundation

/// 把 [Repo] 渲染为离线可打开的单页面 HTML。无状态。
enum StarredHTMLRenderer {

    /// 主入口。
    /// - Parameters:
    ///   - repos: 已 star 的 repos。
    ///   - user: 当前登录用户。
    ///   - exportedAt: 导出时间戳，注入便于测试。
    /// - Returns: 完整 HTML 文档字符串。
    static func render(repos: [Repo], user: GitHubUserDTO, exportedAt: Date = Date()) -> String {
        let dataJSON = encodeData(repos: repos, user: user, exportedAt: exportedAt)
        let heroHTML = buildHero(repos: repos, user: user, exportedAt: exportedAt)

        return """
        <!DOCTYPE html>
        <html lang="en">
        \(buildHead(user: user))
        <body data-theme="dark">
          <div class="app-shell">
            \(heroHTML)
            \(buildToolbar())
            \(buildMain())
            \(buildFooter())
          </div>

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
          <meta name="generator" content="Starcat (https://github.com/dong4j/Starcat)">
          <style>\(buildStylesheet())</style>
        </head>
        """
    }

    // MARK: - Hero header

    private static func buildHero(repos: [Repo], user: GitHubUserDTO, exportedAt: Date) -> String {
        let displayName = (user.name?.isEmpty == false ? user.name! : user.login)
        let initials = String(displayName.prefix(2)).uppercased()
        let bio = user.bio?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileURL = user.htmlUrl ?? "https://github.com/\(user.login)"

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
              <a class="avatar" href="\(htmlEscape(profileURL))" target="_blank" rel="noopener" aria-label="Open GitHub profile">
                <span>\(htmlEscape(initials))</span>
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
                <span class="stat-value">\(langCount)</span>
                <span class="stat-label">Languages</span>
              </div>
              <div class="stat-card">
                <span class="stat-value">\((user.followers ?? 0).htmlFormatted())</span>
                <span class="stat-label">Followers</span>
              </div>
            </div>

            <p class="hero-meta">
              Exported on <time datetime="\(exportedISO)">\(exportedISO)</time>
              by <a href="https://github.com/dong4j/Starcat" target="_blank" rel="noopener">Starcat</a>
              — a native macOS app to manage your GitHub stars.
            </p>
          </div>
        </header>
        """
    }

    // MARK: - Toolbar（搜索 + 排序 + 主题切换）

    private static func buildToolbar() -> String {
        // 注：所有 <option> 文案、placeholder 都英文，与用户"英文优先"要求一致。
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
              <span>Sort</span>
              <select id="sort-select" aria-label="Sort order">
                <option value="starred-desc">Recently starred</option>
                <option value="stars-desc">Most stars</option>
                <option value="pushed-desc">Recently active</option>
                <option value="name-asc">Name (A→Z)</option>
                <option value="created-asc">Oldest project</option>
              </select>
            </label>

            <label class="select">
              <span>Language</span>
              <select id="language-select" aria-label="Filter by language">
                <option value="">All</option>
              </select>
            </label>

            <label class="select">
              <span>Status</span>
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
          Crafted with <a href="https://github.com/dong4j/Starcat" target="_blank" rel="noopener">Starcat</a>
          · Single-file export · Works fully offline · No tracking
        </footer>
        """
    }

    // MARK: - 内嵌数据：JSON 编码

    /// 把 repos + user 序列化为 JSON 字符串，嵌入 `<script id="starred-data">` 里供 JS 消费。
    /// 用 `JSONEncoder` 而非手拼，自动处理引号/换行/控制字符转义。
    private static func encodeData(repos: [Repo], user: GitHubUserDTO, exportedAt: Date) -> String {
        struct Payload: Encodable {
            let user: UserExport
            let exportedAt: String
            let repos: [RepoExport]
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
        }

        let exportRepos = repos.map { r -> RepoExport in
            RepoExport(
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
                languageColor: r.language.flatMap { languageHexColor($0) }
            )
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let payload = Payload(
            user: UserExport(login: user.login, name: user.name, htmlUrl: user.htmlUrl),
            exportedAt: dateFormatter.string(from: exportedAt),
            repos: exportRepos
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
          box-shadow: 0 6px 24px var(--accent-glow);
          transition: transform 0.18s ease;
        }
        .avatar:hover { transform: scale(1.04); text-decoration: none; }

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
        .toolbar-right { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }

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
          padding: 10px 14px 10px 36px;
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

        .select {
          display: flex; flex-direction: column; gap: 2px;
          font-size: 11px; color: var(--text-faint);
          text-transform: uppercase; letter-spacing: 0.5px;
        }
        .select select {
          padding: 6px 10px;
          border-radius: 8px;
          border: 1px solid var(--border);
          background: var(--bg);
          color: var(--text);
          font-size: 13px;
          font-family: inherit;
          cursor: pointer;
          outline: none;
        }
        .select select:focus { border-color: var(--accent); }

        #theme-toggle {
          padding: 8px 12px;
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
        .repo-title {
          margin: 0;
          font-size: 16px; font-weight: 600;
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
        """
    }

    // MARK: - 客户端脚本

    /// 客户端 JS：读 inline JSON → 构建语言/topic 索引 → 注册 input 监听 → 渲染卡片网格。
    /// 整体 < 150 行，原生 ES6+，无第三方依赖。
    private static func buildClientScript() -> String {
        return """
        (function () {
          'use strict';

          const raw = document.getElementById('starred-data').textContent;
          const data = JSON.parse(raw);
          const repos = Array.isArray(data.repos) ? data.repos : [];

          const grid = document.getElementById('grid');
          const emptyState = document.getElementById('empty-state');
          const resultCount = document.getElementById('result-count');
          const searchInput = document.getElementById('search-input');
          const sortSelect = document.getElementById('sort-select');
          const languageSelect = document.getElementById('language-select');
          const statusSelect = document.getElementById('status-select');
          const themeToggle = document.getElementById('theme-toggle');

          // 主题：默认 dark；持久化到 localStorage（如可用）。
          try {
            const saved = localStorage.getItem('starcat-export-theme');
            if (saved === 'light') document.body.dataset.theme = 'light';
          } catch (_) {}
          themeToggle.addEventListener('click', () => {
            const next = document.body.dataset.theme === 'light' ? 'dark' : 'light';
            document.body.dataset.theme = next;
            try { localStorage.setItem('starcat-export-theme', next); } catch (_) {}
          });

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
            head.appendChild(titleH);

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

          function filterRepos(list, query, language, status) {
            const q = (query || '').trim().toLowerCase();
            return list.filter(r => {
              if (language && r.language !== language && !(language === '(no language)' && !r.language)) return false;
              if (status === 'archived' && !r.isArchived) return false;
              if (status === 'active' && r.isArchived) return false;
              if (status === 'fork' && !r.isFork) return false;
              if (status === 'non-fork' && r.isFork) return false;
              if (!q) return true;
              const hay = [
                r.fullName, r.description || '', r.language || '',
                (r.topics || []).join(' '), r.license || ''
              ].join(' ').toLowerCase();
              return hay.indexOf(q) !== -1;
            });
          }

          function apply() {
            const filtered = filterRepos(repos, searchInput.value, languageSelect.value, statusSelect.value);
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
    func htmlFormatted() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
