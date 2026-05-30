//
//  RepoExternalLinks.swift
//  Starcat
//
//  Repo 派生的外部链接（GitHub 子页面 + Homepage）。
//
//  存在意义：
//  - 把 "owner/name" 组装成 GitHub 子页面 URL 的逻辑集中到一处
//  - 子页面（Issues / Releases / Pulls 等）GitHub API 不直接返回 URL，需要拼
//  - 便于单测：构造结果是纯函数，不依赖 NSWorkspace / WKWebView
//
//  覆盖的链接：
//  - repo:    https://github.com/{owner}/{name}                  (= htmlUrl)
//  - issues:  https://github.com/{owner}/{name}/issues
//  - releases:https://github.com/{owner}/{name}/releases
//  - pulls:   https://github.com/{owner}/{name}/pulls
//  - homepage: Repo.homepage（用户自定义，可能为 nil / 非 http）
//

import Foundation

enum RepoExternalLinks {

    /// 仓库主页（= GitHub 上的 owner/name 页面）。
    static func repo(_ repo: Repo) -> URL? {
        URL(string: repo.htmlUrl)
    }

    static func issues(_ repo: Repo) -> URL? {
        URL(string: "\(githubBase(repo))/issues")
    }

    static func releases(_ repo: Repo) -> URL? {
        URL(string: "\(githubBase(repo))/releases")
    }

    static func pulls(_ repo: Repo) -> URL? {
        URL(string: "\(githubBase(repo))/pulls")
    }

    /// Repo.homepage 字段，若非合法 http(s) URL 返回 nil。
    /// 用户在 GitHub 设置 homepage 时可能填 "example.com"（无 scheme），
    /// 这里只接受 http/https 开头的，避免 NSWorkspace 打开本地路径之类的安全风险。
    static func homepage(_ repo: Repo) -> URL? {
        guard let raw = repo.homepage?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: - 内部

    /// 用 owner / name 而非 htmlUrl 拼，避免 htmlUrl 末尾带空格 / 大小写差异等边角问题。
    private static func githubBase(_ repo: Repo) -> String {
        "https://github.com/\(repo.owner)/\(repo.name)"
    }
}
