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
//  - license: https://github.com/{owner}/{name}?tab={SPDX}-1-ov-file
//  - homepage: Repo.homepage（用户自定义，可能为 nil / 非 http）
//

import Foundation

enum RepoExternalLinks {

    // MARK: - 基于 Repo 的便捷重载（Manage 路径）

    /// 仓库主页（= GitHub 上的 owner/name 页面）。
    static func repo(_ repo: Repo) -> URL? {
        URL(string: repo.htmlUrl)
    }

    static func issues(_ repo: Repo) -> URL? {
        issues(owner: repo.owner, name: repo.name)
    }

    static func releases(_ repo: Repo) -> URL? {
        releases(owner: repo.owner, name: repo.name)
    }

    static func pulls(_ repo: Repo) -> URL? {
        pulls(owner: repo.owner, name: repo.name)
    }

    /// Repo.homepage 字段，若非合法 http(s) URL 返回 nil。
    /// 用户在 GitHub 设置 homepage 时可能填 "example.com"（无 scheme），
    /// 这里只接受 http/https 开头的，避免 NSWorkspace 打开本地路径之类的安全风险。
    static func homepage(_ repo: Repo) -> URL? {
        homepage(raw: repo.homepage)
    }

    /// License 概览页（= GitHub 仓库页侧栏 license 胶囊的跳转目标）。
    ///
    /// GitHub 前端会把页内锚点 `#{SPDX}-1-ov-file` 规范化成 `?tab={SPDX}-1-ov-file`
    /// 查询参数（2026-09 抓包验证：public-apis → MIT、psf/requests → Apache-2.0），
    /// 落地后高亮并滚动到 LICENSE 文件行。仅标准 SPDX 可构造；`Other` / `NOASSERTION`
    /// 在 GitHub 上本来就不提供该链接（如 FFmpeg 胶囊无 href），返回 nil 让调用方
    /// 保持纯展示，避免拼出 404。
    static func license(owner: String, name: String, spdx: String?) -> URL? {
        guard let spdx = spdx?.trimmingCharacters(in: .whitespacesAndNewlines),
              !spdx.isEmpty,
              spdx.caseInsensitiveCompare("Other") != .orderedSame,
              spdx.caseInsensitiveCompare("NOASSERTION") != .orderedSame else { return nil }
        return URL(string: "\(githubBase(owner: owner, name: name))?tab=\(spdx)-1-ov-file")
    }

    static func license(_ repo: Repo) -> URL? {
        license(owner: repo.owner, name: repo.name, spdx: repo.license)
    }

    // MARK: - 基于 owner/name 的拼接重载（trending / weekly / activity 共用）
    //
    // 子页面 URL（issues / pulls / releases）GitHub API 不直接返回，必须按 owner/name
    // 拼接。Trending / Weekly 等远端源没有本地 `Repo` 对象但 owner/name 一定有，
    // 走这套重载就能复用同一份 URL 规则。

    static func issues(owner: String, name: String) -> URL? {
        URL(string: "\(githubBase(owner: owner, name: name))/issues")
    }

    static func releases(owner: String, name: String) -> URL? {
        URL(string: "\(githubBase(owner: owner, name: name))/releases")
    }

    static func pulls(owner: String, name: String) -> URL? {
        URL(string: "\(githubBase(owner: owner, name: name))/pulls")
    }

    /// 通用 homepage 解析：把"可能为 nil / 不带 scheme / 含空白"的原始字符串过滤成合法 http(s) URL。
    /// 调用方（如 `ToolbarRepoSelection`）拿到的 `homepage` 字段类型不固定（String? / URL?），
    /// 这里只接 String?。
    static func homepage(raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: - 内部

    /// 用 owner / name 而非 htmlUrl 拼，避免 htmlUrl 末尾带空格 / 大小写差异等边角问题。
    private static func githubBase(owner: String, name: String) -> String {
        "https://github.com/\(owner)/\(name)"
    }
}
