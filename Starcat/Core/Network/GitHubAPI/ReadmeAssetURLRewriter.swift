//
//  ReadmeAssetURLRewriter.swift
//  Starcat
//
//  README HTML 内 `<img>` 相对路径重写工具（HOM-201 P1-2，2026-06-14）。
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
//  策略（与原 ReadmeWebView 实现一致，**仅是位置迁移**）
//  ────────────────────────────────────────────────────────────────────────────
//
//  触发原因：GitHub HTML render 端点对原生 HTML `<img>` 不做 URL 重写，
//  用 `repo.htmlUrl` 作 baseURL 时 `./logo.PNG` 会被浏览器解析为
//  `https://github.com/owner/logo.PNG` → 404。
//
//  - 完整 URL（http(s):// / data: / 协议相对 //） → 不动
//  - GitHub 站点根路径 raw 图片（`/{owner}/{repo}/raw/{ref}/{path}`）
//    → 改写为 `https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}`
//  - 其余视作相对路径 → 拼到 `https://raw.githubusercontent.com/{owner}/{repo}/HEAD/`
//    - HEAD 自动指向 default branch，无需额外查询 default branch
//    - 去掉前导 `./` 与 `/`，与仓库根对齐
//  - owner/repo 缺失 → 直接原样返回（保守，宁可坏图不要错重写）
//
//  正则只匹配双引号包裹的 src（GitHub render 出来稳定用双引号），不引入新依赖
//  （SwiftSoup 等）以保留 zero-dep 边界。
//

import Foundation

/// README HTML `<img>` 相对路径重写工具。详见文件头注释。
enum ReadmeAssetURLRewriter {

    /// 把 HTML 中所有 `<img src="相对路径">` 重写为 raw.githubusercontent.com 绝对 URL。
    ///
    /// 详见文件头 `策略` 节。
    ///
    /// - Parameters:
    ///   - html: GitHub `Accept: application/vnd.github.html` 返回的 HTML 片段
    ///   - owner: 仓库 owner（缺失 / 空字符串则不重写）
    ///   - repo: 仓库 name（缺失 / 空字符串则不重写）
    /// - Returns: 重写后的 HTML；输入 HTML 不含 `<img>` 时原样返回（不分配新字符串）
    static func rewrite(in html: String, owner: String?, repo: String?) -> String {
        guard let owner, let repo, !owner.isEmpty, !repo.isEmpty else { return html }
        let rawBase = "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/"

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
            let rewritten = rewriteOne(originalSrc, rawBase: rawBase)
            result += "<img\(prefix)src=\"\(rewritten)\""

            cursor = m.range.location + m.range.length
        }
        result += nsHtml.substring(from: cursor)
        return result
    }

    /// 单个 `src` 的重写策略：
    /// - 绝对/协议相对/data URI/mailto/javascript 一律放过；
    /// - GitHub 站点根路径 raw 图片改写为 raw.githubusercontent.com；
    /// - 其余视为相对路径，去掉前导 `./` 与 `/`，拼到 `rawBase`。
    ///
    /// 暴露为 `internal` 是为了单测能精确覆盖各种边界 src。
    static func rewriteOne(_ src: String, rawBase: String) -> String {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
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
