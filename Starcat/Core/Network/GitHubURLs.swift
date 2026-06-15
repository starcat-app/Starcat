//
//  GitHubURLs.swift
//  Starcat
//
//  GitHub **网页**（github.com 主域名）跳转链接的集中目录。
//
//  与 `AppEndpoints` 的区别：
//  - `AppEndpoints` 管 **REST API** 端点（api.github.com、自建后端、OAuth），调用方是 actor /
//    URLSession 发请求。
//  - 本文件管 **网页跳转链接**（github.com/{login}, github.com/{owner}/{repo} 等），调用方
//    是 SwiftUI `Link` / `NSWorkspace.open(_:)` 让用户在浏览器里打开。
//
//  之所以分成两个文件而不是合并：① 语义维度不同（REST vs 浏览器），混在一起会让"端点配置"
//  这个心智模型变模糊；② 调用方不同（actor vs View），分开后 grep 标识符更精准。
//
//  非 GitHub 的网页链接（starcat.app / x.com / 致谢列表里的第三方 GitHub repo）不放本文件——
//  它们是产品文案 / 装饰链接性质，与"GitHub 用户/仓库主页"的"参数化生成"语义不同；就近放
//  在各 View 内常量即可。
//

import Foundation

/// GitHub 网页跳转链接集中目录。
///
/// 不可实例化，仅暴露静态工厂方法。
enum GitHubURLs {

    /// `github.com` 主域名根。一般不直接使用——所有工厂方法已封装拼接。
    static let baseURL = URL(string: "https://github.com")!

    // MARK: - 用户主页

    /// 用户主页：`https://github.com/{login}`。
    static func userProfile(login: String) -> URL {
        baseURL.appendingPathComponent(login)
    }

    /// 用户主页 + Stars Tab：`https://github.com/{login}?tab=stars`。
    /// 用 URLComponents 拼 query 而非字符串插值，避免 login 含特殊字符时 URL 失效。
    static func userStarsTab(login: String) -> URL {
        userTab(login: login, tab: "stars")
    }

    /// 用户主页 + Followers Tab：`https://github.com/{login}?tab=followers`。
    static func userFollowersTab(login: String) -> URL {
        userTab(login: login, tab: "followers")
    }

    /// 用户主页 + Following Tab：`https://github.com/{login}?tab=following`。
    static func userFollowingTab(login: String) -> URL {
        userTab(login: login, tab: "following")
    }

    // MARK: - 仓库主页

    /// 仓库主页：`https://github.com/{owner}/{repo}`。
    static func repo(owner: String, repo: String) -> URL {
        baseURL.appendingPathComponent(owner).appendingPathComponent(repo)
    }

    /// 仓库主页（用 fullName 拼）：`https://github.com/{fullName}`，其中 fullName = "owner/repo"。
    /// 容错：如果 fullName 解析失败（极端罕见，如含非法字符），降级回 baseURL，避免崩溃。
    static func repo(fullName: String) -> URL {
        URL(string: "\(baseURL.absoluteString)/\(fullName)") ?? baseURL
    }

    // MARK: - Commit 详情

    /// 仓库 commit 详情页：`https://github.com/{owner}/{repo}/commit/{sha}`。
    ///
    /// `sha` 接受 short（7 位）/ full（40 位）任意长度，GitHub 会自动解析并 302 跳到 canonical full
    /// sha。出于稳定性与可读性考虑，**调用方应优先传 full sha**（40 字符），short sha 仅在缺少
    /// full 时降级使用 —— 理由有二：① short sha 在大仓库存在碰撞风险，full 永远唯一；② GitHub UI
    /// 在比对 commit 时会以 URL 段为准，full sha 直达，short 会多一次 302。
    static func repoCommit(owner: String, repo: String, sha: String) -> URL {
        baseURL.appendingPathComponent(owner)
            .appendingPathComponent(repo)
            .appendingPathComponent("commit")
            .appendingPathComponent(sha)
    }

    // MARK: - Private

    /// 用户主页 + 任意 tab 的公共拼装。
    private static func userTab(login: String, tab: String) -> URL {
        var components = URLComponents(url: userProfile(login: login), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "tab", value: tab)]
        // URLComponents 解析失败几率极低（baseURL 是常量、tab 是字面量）；万一失败降级回主页。
        return components?.url ?? userProfile(login: login)
    }
}
