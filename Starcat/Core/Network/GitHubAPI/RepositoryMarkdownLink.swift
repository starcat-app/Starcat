//
//  RepositoryMarkdownLink.swift
//  Starcat
//
//  把 README 里的点击 URL 判定为「当前仓库的 Markdown 文件」。
//
//  为什么单独抽纯函数：链接形态很多（相对路径、blob、raw、www、锚点），
//  必须能脱离 WebView / 网络做单测。这里不猜「是不是多语言」，只认
//  owner/repo 匹配 + markdown 扩展名，避免靠锚文本或文件名猜语言。
//

import Foundation

/// 同仓 Markdown 文件的定位信息。
///
/// `ref` 保留 URL 里的分支 / tag / `HEAD`，拉 Contents API 和拼回退浏览器地址时都用它。
struct RepositoryMarkdownLinkTarget: Equatable, Hashable, Sendable {
    let owner: String
    let repo: String
    let ref: String
    let path: String

    /// 会话缓存 key。owner/repo 忽略大小写，避免同一仓两种写法各缓存一份。
    var cacheKey: String {
        "\(owner.lowercased())/\(repo.lowercased())@\(ref):\(path)"
    }

    /// 拉取失败时回退浏览器用的 GitHub blob 地址。
    var browserURL: URL {
        let encodedPath = Self.encodedPath(path)
        return URL(string: "https://github.com/\(owner)/\(repo)/blob/\(ref)/\(encodedPath)")
            ?? URL(string: "https://github.com/\(owner)/\(repo)")!
    }

    /// 该文件所在目录对应的 blob 基址，给独立窗解析相对链接。
    ///
    /// 必须带末尾 `/`：否则 WebKit 会把最后一段当成文件名丢掉，
    /// 和 `ReadmeWebView.repositoryContentBaseURL` 是同一类坑。
    var contentBaseURL: URL {
        let repoURL = URL(string: "https://github.com/\(owner)/\(repo)")!
        var base = repoURL.appendingPathComponent("blob/\(ref)", isDirectory: true)
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty, directory != "." {
            base = base.appendingPathComponent(directory, isDirectory: true)
        }
        return base
    }

    var windowTitle: String {
        "\(owner)/\(repo) · \(path)"
    }

    private static func encodedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? String(component)
            }
            .joined(separator: "/")
    }
}

/// README 点击链接分类。只回答「能不能按同仓 Markdown 在 App 内打开」。
enum RepositoryMarkdownLink {
    /// GitHub 会按 Markdown 渲染的扩展名。不含 `.mdx`（JSX）和 `.rst`。
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]

    /// 在「当前仓库」上下文里分类。其它仓、Issue、目录、图片一律返回 nil。
    static func classify(_ url: URL, owner: String, repo: String) -> RepositoryMarkdownLinkTarget? {
        guard let parsed = parse(url) else { return nil }
        guard parsed.owner.caseInsensitiveCompare(owner) == .orderedSame,
              parsed.repo.caseInsensitiveCompare(repo) == .orderedSame
        else { return nil }
        return parsed
    }

    /// 不绑定当前仓，只解析 GitHub Markdown 文件 URL。供单测覆盖各种形态。
    static func parse(_ url: URL) -> RepositoryMarkdownLinkTarget? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if host == "github.com" || host == "www.github.com" {
            return parseGitHubSite(parts)
        }
        if host == "raw.githubusercontent.com" {
            return parseRawSite(parts)
        }
        return nil
    }

    // MARK: - Private

    /// `/owner/repo/blob/{ref}/{path}` 或 `/owner/repo/raw/{ref}/{path}`。
    ///
    /// `ref` 只取 blob/raw 后的第一段。带斜杠的分支名（`feature/foo`）会判错，
    /// 这是 URL 本身的歧义；失败后上层回退浏览器，不在这里猜。
    private static func parseGitHubSite(_ parts: [String]) -> RepositoryMarkdownLinkTarget? {
        guard parts.count >= 5 else { return nil }
        let kind = parts[2].lowercased()
        guard kind == "blob" || kind == "raw" else { return nil }
        let fileParts = Array(parts.dropFirst(4))
        return makeTarget(owner: parts[0], repo: parts[1], ref: parts[3], fileParts: fileParts)
    }

    /// `/owner/repo/{ref}/{path}`。
    private static func parseRawSite(_ parts: [String]) -> RepositoryMarkdownLinkTarget? {
        guard parts.count >= 4 else { return nil }
        let fileParts = Array(parts.dropFirst(3))
        return makeTarget(owner: parts[0], repo: parts[1], ref: parts[2], fileParts: fileParts)
    }

    private static func makeTarget(
        owner: String,
        repo: String,
        ref: String,
        fileParts: [String]
    ) -> RepositoryMarkdownLinkTarget? {
        guard !owner.isEmpty, !repo.isEmpty, !ref.isEmpty, !fileParts.isEmpty else { return nil }
        let path = fileParts.joined(separator: "/")
        guard let ext = fileParts.last?.split(separator: ".").last.map({ String($0).lowercased() }),
              markdownExtensions.contains(ext)
        else { return nil }
        return RepositoryMarkdownLinkTarget(owner: owner, repo: repo, ref: ref, path: path)
    }
}
