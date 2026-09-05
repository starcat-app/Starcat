//
//  OwnerCardExternalLink.swift
//  Starcat
//
//  把 GitHub 传统 profile 字段与独立 Social accounts 响应合并为 Owner 卡片展示模型。
//

import Foundation

/// Owner 卡片可点击的公开外链。
///
/// 该类型集中处理三项约束：只接受 HTTP(S)、同一 URL 只展示一次、Social accounts
/// 已提供 X 时不再用 `twitter_username` 生成重复入口。
struct OwnerCardExternalLink: Identifiable, Equatable, Sendable {

    /// 卡片只需要区分 X 与普通链接；website 单列是为了保持既有入口顺序和测试语义。
    enum Kind: Equatable, Sendable {
        case website
        case x
        case generic

        /// 延续项目现有 Profile 链接的 SF Symbol，不额外引入品牌图片资源。
        var systemImage: String {
            switch self {
            case .x:
                "bird"
            case .website, .generic:
                "link"
            }
        }
    }

    let kind: Kind
    let url: URL

    /// URL 已在构造阶段去重，可直接作为 SwiftUI `ForEach` 的稳定身份。
    var id: String { Self.canonicalKey(for: url) }

    /// 合并 `blog`、Social accounts 与 `twitter_username` 兼容字段。
    ///
    /// 顺序保持为网站优先、GitHub Social accounts 原顺序、X 兜底最后；因此既不改变
    /// 已有网站按钮的位置，也能忠实保留 GitHub 页面上的社交账号排列。
    static func make(
        profile: GitHubUserDTO?,
        socialAccounts: [GitHubSocialAccountDTO]
    ) -> [OwnerCardExternalLink] {
        var links: [OwnerCardExternalLink] = []
        var seenURLs: Set<String> = []

        func append(rawURL: String?, kind: Kind, allowsMissingScheme: Bool) {
            guard let url = normalizedURL(from: rawURL, allowsMissingScheme: allowsMissingScheme) else {
                return
            }
            guard seenURLs.insert(canonicalKey(for: url)).inserted else { return }
            links.append(.init(kind: kind, url: url))
        }

        append(rawURL: profile?.blog, kind: .website, allowsMissingScheme: true)

        for account in socialAccounts {
            append(
                rawURL: account.url,
                kind: socialKind(provider: account.provider, rawURL: account.url),
                allowsMissingScheme: false
            )
        }

        // 老账号或接口临时失败时，`twitter_username` 仍能保证 X 入口可用。
        if !links.contains(where: { $0.kind == .x }),
           let handle = normalizedXHandle(profile?.twitterUsername) {
            append(rawURL: "https://x.com/\(handle)", kind: .x, allowsMissingScheme: false)
        }

        return links
    }

    /// provider 偶尔为 generic，因此同时检查 host，避免 X 链接退化为普通链图标。
    private static func socialKind(provider: String, rawURL: String) -> Kind {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedProvider == "twitter" || normalizedProvider == "x" {
            return .x
        }

        let host = normalizedURL(from: rawURL, allowsMissingScheme: false)?.host?.lowercased()
        if host == "x.com" || host == "www.x.com" ||
            host == "twitter.com" || host == "www.twitter.com" {
            return .x
        }
        return .generic
    }

    /// 只接受可安全交给 `NSWorkspace` 的网页 URL；Social accounts 不自动猜测 scheme。
    private static func normalizedURL(from raw: String?, allowsMissingScheme: Bool) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let candidate: String
        if allowsMissingScheme,
           !trimmed.hasPrefix("http://"),
           !trimmed.hasPrefix("https://") {
            candidate = "https://\(trimmed)"
        } else {
            candidate = trimmed
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private static func normalizedXHandle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let handle = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        return handle.isEmpty ? nil : handle
    }

    /// host 和 scheme 不区分大小写，末尾 `/` 也不应制造两个视觉相同的按钮。
    private static func canonicalKey(for url: URL) -> String {
        url.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}
