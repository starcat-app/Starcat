//
//  ReadmeAssetURLRewriter.swift
//  Starcat
//
//  README HTML 内图片与视频资源地址重写工具。
//
//  ────────────────────────────────────────────────────────────────────────────
//  从渲染层迁移到 IO 层
//  ────────────────────────────────────────────────────────────────────────────
//
//  以前这段正则替换逻辑住在 `ReadmeWebView`（UI 层），每次列表切换 repo 触发
//  `loadIfNeeded` 都会扫描整段 HTML 跑一次 NSRegularExpression —— 几百 KB 的大
//  README（react 这种）在 8KB+ 字符串上跑全文匹配，每切一次都重新算，浪费
//  且明显延迟首帧。
//
//  本类把同一份逻辑提到 `ReadmeAPI` 在 200 / promote 路径 upsert **之前**调用,
//  rewrite 后的 HTML 直接落到 `readmes.rendered_html` / `trending_readmes.rendered_html`
//  里：
//  - 每条记录只跑一次正则,且发生在 IO 线程而非渲染线程；
//  - 后续详情页切换该 repo 时直接拿"已 rewrite 完成"的 HTML 喂 WKWebView，
//    渲染层不再 rewrite；
//  - 一次性、单向（不会有"先存 raw 再渲染时 rewrite"的不一致风险）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  图片策略（与原 ReadmeWebView 实现一致，**仅是位置迁移**）
//  ────────────────────────────────────────────────────────────────────────────
//
//  触发原因：GitHub HTML render 端点对原生 HTML `<img>` 不做 URL 重写，
//  用 `repo.htmlUrl` 作 baseURL 时 `./logo.PNG` 会被浏览器解析为
//  `https://github.com/owner/logo.PNG` → 404。
//
//  - 完整 URL（http(s):// / data: / 协议相对 //） → 不动
//  - GitHub 站点根路径 raw 图片（`/{owner}/{repo}/raw/{ref}/{path}`）
//    → 改写为 `https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}`
//  - 其余视作相对路径 → 拼到 README 文件所在目录对应的 raw URL：
//    `https://raw.githubusercontent.com/{owner}/{repo}/HEAD/{readmeDir}/`
//    - HEAD 自动指向 default branch，无需额外查询 default branch
//    - GitHub HTML 外层 `data-path=".github/README.md"` 表示本文档位于 `.github/`
//      目录，`img/logo.png` 必须解析到 `.github/img/logo.png`，不能按仓库根拼接
//  - owner/repo 缺失 → 直接原样返回（保守，宁可坏图不要错重写）
//
//  视频策略（GitHub Issue #107，2026-08-22）：
//  - GitHub 上传的视频会被 HTML API 渲染为 `<video src="短时效签名 URL">`；
//  - `rendered_html` 的缓存寿命远长于签名 URL，直接落库会导致视频很快失效；
//  - 从 `private-user-images.githubusercontent.com` path 提取 attachment UUID，改写为
//    `https://github.com/user-attachments/assets/<UUID>`，由 GitHub 在播放时生成新重定向；
//  - UUID 无法可靠提取时保持原样，避免把第三方或未知地址误改坏。
//
//  正则只匹配双引号包裹的属性（GitHub render 出来稳定用双引号），不引入新依赖
//  （SwiftSoup 等）以保留 zero-dep 边界。签名 URL 不写日志，避免泄露临时访问参数。
//

import Foundation

/// README HTML 图片与视频资源地址重写工具。详见文件头注释。
enum ReadmeAssetURLRewriter {

    /// 规范化 README HTML 中的图片与 GitHub attachment 视频地址。
    ///
    /// 详见文件头 `策略` 节。
    ///
    /// - Parameters:
    ///   - html: GitHub `Accept: application/vnd.github.html` 返回的 HTML 片段
    ///   - owner: 仓库 owner（缺失 / 空字符串则不重写）
    ///   - repo: 仓库 name（缺失 / 空字符串则不重写）
    /// - Returns: 重写后的 HTML；没有命中资源规则时返回原字符串
    static func rewrite(in html: String, owner: String?, repo: String?) -> String {
        guard let owner, let repo, !owner.isEmpty, !repo.isEmpty else { return html }
        let rawRoot = "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/"
        let documentDirectory = readmeDocumentDirectory(from: html)
        let rawBase = rawRoot + documentDirectory

        let imageRewritten = rewriteImageSources(
            in: html,
            rawBase: rawBase,
            rawRoot: rawRoot,
            documentDirectory: documentDirectory
        )
        return rewriteGitHubVideoSources(in: imageRewritten)
    }

    /// 图片规则沿用既有实现，单独收口后让视频规范化不会改变图片匹配边界。
    private static func rewriteImageSources(
        in html: String,
        rawBase: String,
        rawRoot: String,
        documentDirectory: String
    ) -> String {
        // <img ...src="xxx"...> ；捕获 1 = src 前的属性串，捕获 2 = src 值
        let pattern = #"<img\b([^>]*?)\bsrc\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let nsHtml = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for m in matches {
            let unchanged = NSRange(location: cursor, length: m.range.location - cursor)
            result += nsHtml.substring(with: unchanged)

            let prefix = nsHtml.substring(with: m.range(at: 1))
            let originalSrc = nsHtml.substring(with: m.range(at: 2))
            let rewritten = rewriteOne(
                originalSrc,
                rawBase: rawBase,
                rawRoot: rawRoot,
                documentDirectory: documentDirectory
            )
            result += "<img\(prefix)src=\"\(rewritten)\""

            cursor = m.range.location + m.range.length
        }
        result += nsHtml.substring(from: cursor)
        return result
    }

    /// 把 GitHub HTML API 生成的短时效视频地址改成稳定 attachment URL。
    ///
    /// 同时处理 `src` 与 `data-canonical-src`，避免旧签名继续残留在落库 HTML 中。
    /// 只扫描 `<video ...>` 开始标签，不触碰 iframe、object 或普通链接。
    private static func rewriteGitHubVideoSources(in html: String) -> String {
        let tagPattern = #"<video\b[^>]*>"#
        guard let tagRegex = try? NSRegularExpression(
            pattern: tagPattern,
            options: [.caseInsensitive]
        ) else {
            return html
        }

        let nsHtml = html as NSString
        let matches = tagRegex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            let tag = nsHtml.substring(with: match.range)
            let rewrittenTag = rewriteVideoSourceAttributes(in: tag)
            guard rewrittenTag != tag,
                  let range = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(range, with: rewrittenTag)
        }
        return result
    }

    /// 只替换视频标签中的资源属性值，保留 GitHub 生成的 controls、muted、class 与 style。
    private static func rewriteVideoSourceAttributes(in tag: String) -> String {
        let attributePattern = #"\b(data-canonical-src|src)\s*=\s*"([^"]+)""#
        guard let attributeRegex = try? NSRegularExpression(
            pattern: attributePattern,
            options: [.caseInsensitive]
        ) else {
            return tag
        }

        let nsTag = tag as NSString
        let matches = attributeRegex.matches(
            in: tag,
            options: [],
            range: NSRange(location: 0, length: nsTag.length)
        )
        guard !matches.isEmpty else { return tag }

        var result = tag
        for match in matches.reversed() {
            let sourceRange = match.range(at: 2)
            let source = nsTag.substring(with: sourceRange)
            guard let stableURL = stableGitHubAttachmentURL(from: source),
                  let range = Range(sourceRange, in: result)
            else { continue }
            result.replaceSubrange(range, with: stableURL)
        }
        return result
    }

    /// GitHub 的签名视频 path 会保留原 attachment UUID；只在 host 与 UUID 都准确时重写。
    private static func stableGitHubAttachmentURL(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host?.lowercased() == "private-user-images.githubusercontent.com"
        else { return nil }

        let fileName = url.deletingPathExtension().lastPathComponent
        let uuidPattern = #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#
        guard let uuidRegex = try? NSRegularExpression(
            pattern: uuidPattern,
            options: [.caseInsensitive]
        ) else { return nil }

        let nsFileName = fileName as NSString
        let searchRange = NSRange(location: 0, length: nsFileName.length)
        guard let match = uuidRegex.firstMatch(in: fileName, options: [], range: searchRange),
              let matchRange = Range(match.range(at: 1), in: fileName),
              let uuid = UUID(uuidString: String(fileName[matchRange]))
        else { return nil }

        return "https://github.com/user-attachments/assets/\(uuid.uuidString.lowercased())"
    }

    /// 单个 `src` 的重写策略：
    /// - 绝对/协议相对/data URI/mailto/javascript 一律放过；
    /// - GitHub 站点根路径 raw 图片改写为 raw.githubusercontent.com；
    /// - 其余视为相对路径，去掉前导 `./` 与 `/`，拼到 `rawBase`。
    ///
    /// 暴露为 `internal` 是为了单测能精确覆盖各种边界 src。
    static func rewriteOne(_ src: String, rawBase: String) -> String {
        rewriteOne(src, rawBase: rawBase, rawRoot: rawBase, documentDirectory: "")
    }

    /// 单个 `src` 的重写策略（带 README 文档目录上下文）。
    ///
    /// `data-path=".github/README.md"` 这类 GitHub HTML wrapper 表明图片相对路径应以
    /// README 所在目录为基准，而不是仓库根目录。旧版本已经把这类路径错误落库为
    /// `.../HEAD/img/foo.png`，所以这里也会在同仓库 `HEAD/` raw URL 上做一次定向修复。
    static func rewriteOne(
        _ src: String,
        rawBase: String,
        rawRoot: String,
        documentDirectory: String
    ) -> String {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix(rawRoot.lowercased()),
           !documentDirectory.isEmpty,
           let repaired = repairSameRepoHeadRawURL(
            trimmed,
            rawRoot: rawRoot,
            documentDirectory: documentDirectory
           ) {
            return repaired
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("//") || lower.hasPrefix("data:")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("javascript:") {
            return trimmed
        }
        if let githubRawURL = githubRootRawURL(from: trimmed) {
            return githubRawURL
        }
        var clean = Substring(trimmed)
        if clean.hasPrefix("./") { clean = clean.dropFirst(2) }
        while clean.hasPrefix("/") { clean = clean.dropFirst() }
        return rawBase + String(clean)
    }

    /// 从 GitHub HTML wrapper 的 `data-path` 推导 README 所在目录。
    ///
    /// GitHub 仓库主页可能展示 `.github/README.md` 作为 overview README。HTML render
    /// 输出会带 `data-path=".github/README.md"`，其内部 `<img src="img/logo.png">`
    /// 是相对 `.github/` 的。如果忽略该目录直接拼仓库根，会得到 404 的 raw URL。
    private static func readmeDocumentDirectory(from html: String) -> String {
        let pattern = #"data-path\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return ""
        }
        let nsHtml = html as NSString
        let searchRange = NSRange(location: 0, length: min(nsHtml.length, 4096))
        guard let match = regex.firstMatch(in: html, options: [], range: searchRange) else {
            return ""
        }
        let path = nsHtml.substring(with: match.range(at: 1))
        guard let slashIndex = path.lastIndex(of: "/") else { return "" }
        let directory = path[..<path.index(after: slashIndex)]
        return sanitizeRelativeDirectory(String(directory))
    }

    /// 只保留安全的仓库内相对目录，避免 HTML 异常值影响 raw URL 拼接。
    private static func sanitizeRelativeDirectory(_ directory: String) -> String {
        var clean = Substring(directory.trimmingCharacters(in: .whitespacesAndNewlines))
        while clean.hasPrefix("./") { clean = clean.dropFirst(2) }
        while clean.hasPrefix("/") { clean = clean.dropFirst() }
        guard !clean.contains("..") else { return "" }
        return clean.isEmpty || clean.hasSuffix("/") ? String(clean) : String(clean) + "/"
    }

    /// 修复旧缓存中已经被错误改写过的同仓库 raw HEAD URL。
    ///
    /// 旧逻辑把 `.github/README.md` 内的 `img/javalin.png` 写成
    /// `.../HEAD/img/javalin.png`。这种 URL 看起来是绝对 URL，普通 rewrite 会跳过；
    /// 这里仅在 HTML 明确声明 README 位于子目录时，把缺失的目录补回去。
    private static func repairSameRepoHeadRawURL(
        _ src: String,
        rawRoot: String,
        documentDirectory: String
    ) -> String? {
        guard src.hasPrefix(rawRoot), !documentDirectory.isEmpty else { return nil }
        let relativePath = String(src.dropFirst(rawRoot.count))
        guard !relativePath.isEmpty, !relativePath.hasPrefix(documentDirectory) else { return nil }
        return rawRoot + documentDirectory + relativePath
    }

    /// 识别 GitHub HTML 渲染结果里常见的站点根路径 raw 图片。
    ///
    /// 这种 URL 看起来像相对路径，但语义是 GitHub 站点路径：
    /// `/javalin/javalin/raw/master/.github/img/javalin.png`。如果继续按仓库根相对路径拼接，
    /// 会得到错误的 `.../HEAD/javalin/javalin/raw/master/...`，WebView 只能显示坏图占位。
    private static func githubRootRawURL(from src: String) -> String? {
        guard src.hasPrefix("/") else { return nil }

        let parts = src.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2].lowercased() == "raw" else { return nil }

        let owner = parts[0]
        let repo = parts[1]
        let ref = parts[3]
        let path = parts.dropFirst(4).joined(separator: "/")
        guard !owner.isEmpty, !repo.isEmpty, !ref.isEmpty, !path.isEmpty else { return nil }

        return "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(path)"
    }
}
