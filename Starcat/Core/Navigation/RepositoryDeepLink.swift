//
//  RepositoryDeepLink.swift
//  Starcat
//
//  公开仓库分享链接的唯一解析与生成入口。
//
//  关键约束：
//  - 对外只分享 HTTPS URL，让未安装 Starcat 的接收者仍能看到网页与 OG 卡片；
//  - 已安装客户端由 Universal Links 接管同一个 URL，不需要私有 scheme 做中转；
//  - owner / repo 在进入导航层前完成严格校验，避免把任意路径误当成仓库请求。
//

import Foundation

/// 一个已经过格式校验的 GitHub 公开仓库定位目标。
struct RepositoryDeepLink: Equatable, Hashable, Sendable {
    static let publicHost = "starcat.ink"

    let owner: String
    let name: String
    /// GitHub 全局仓库 ID 可跨 rename 保持稳定；旧链接没有该参数时仍按 owner/name 工作。
    let repositoryID: Int64?

    /// 从明确的 owner / repo 构造目标。格式不符合 GitHub 仓库命名约束时返回 nil。
    init?(owner: String, name: String, repositoryID: Int64? = nil) {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let repositoryID, repositoryID <= 0 { return nil }
        guard Self.isValidOwner(normalizedOwner),
              Self.isValidRepositoryName(normalizedName)
        else {
            return nil
        }
        self.owner = normalizedOwner
        self.name = normalizedName
        self.repositoryID = repositoryID
    }

    /// 从 Repo.fullName 构造，要求严格为 `owner/repo` 两段。
    init?(fullName: String, repositoryID: Int64? = nil) {
        let components = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        self.init(owner: String(components[0]), name: String(components[1]), repositoryID: repositoryID)
    }

    /// 解析 Universal Link；同时兼容内部调试可用的 `starcat://repo/owner/name`。
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return nil }

        guard let percentEncodedPath = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath else { return nil }
        let encodedComponents = percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }

        switch scheme {
        case "https":
            guard url.host?.lowercased() == Self.publicHost,
                  encodedComponents.count == 3,
                  encodedComponents[0] == "r"
            else { return nil }
            let query = Self.parseQuery(from: url)
            guard query.isValid else { return nil }
            self.init(owner: encodedComponents[1], name: encodedComponents[2], repositoryID: query.repositoryID)

        case "starcat":
            guard url.host?.lowercased() == "repo", encodedComponents.count == 2 else { return nil }
            let query = Self.parseQuery(from: url)
            guard query.isValid else { return nil }
            self.init(owner: encodedComponents[0], name: encodedComponents[1], repositoryID: query.repositoryID)

        default:
            return nil
        }
    }

    /// 可公开复制、可被爬虫抓取、也可被 Universal Links 接管的唯一链接形态。
    var publicURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.publicHost
        components.path = "/r/\(owner)/\(name)"
        var queryItems = [URLQueryItem(name: "v", value: "1")]
        if let repositoryID {
            queryItems.append(URLQueryItem(name: "rid", value: String(repositoryID)))
        }
        components.queryItems = queryItems
        // owner / repo 已经过 ASCII 白名单校验，因此构造失败代表 Foundation 异常，
        // 不应静默退化为 GitHub URL或私有 scheme，避免复制出两套分享协议。
        return components.url!
    }

    /// App 内打开使用的私有 scheme。Alfred 等本机外部集成只应从这个已校验模型
    /// 构造 URL，不能自行拼接 owner/name 后交给系统执行。
    var appURL: URL {
        var components = URLComponents()
        components.scheme = "starcat"
        components.host = "repo"
        components.path = "/\(owner)/\(name)"
        var queryItems = [URLQueryItem(name: "v", value: "1")]
        if let repositoryID {
            queryItems.append(URLQueryItem(name: "rid", value: String(repositoryID)))
        }
        components.queryItems = queryItems
        return components.url!
    }

    /// 版本参数存在时只接受当前 v=1，避免错误解释未来协议；没有 rid 的旧链接
    /// 仍然有效，并回退到 owner/name 定位。
    private static func parseQuery(from url: URL) -> (isValid: Bool, repositoryID: Int64?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let version = items.first(where: { $0.name == "v" })?.value, version != "1" {
            return (false, nil)
        }
        guard let rawID = items.first(where: { $0.name == "rid" })?.value else {
            return (true, nil)
        }
        guard let repositoryID = Int64(rawID), repositoryID > 0 else { return (false, nil) }
        return (true, repositoryID)
    }

    private static func isValidOwner(_ value: String) -> Bool {
        guard (1...39).contains(value.utf8.count),
              value.first != "-",
              value.last != "-"
        else { return false }
        return value.utf8.allSatisfy { byte in
            byte.isASCIILetterOrDigit || byte == 45 // "-"
        }
    }

    private static func isValidRepositoryName(_ value: String) -> Bool {
        guard (1...100).contains(value.utf8.count), value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy { byte in
            byte.isASCIILetterOrDigit || byte == 46 || byte == 95 || byte == 45 // ".", "_", "-"
        }
    }
}

/// 一个已经过格式校验的仓库 Release 定位目标。
///
/// Release 链接只用于 Starcat 内部导航，不把 GitHub Release URL 当作执行入口：
/// Widget 快照因此只携带受控的 owner / repo / 数字 ID，App 收到 URL 后仍通过
/// 本地 Release 时间线展示数据，找不到指定 Release 时也只降级到该时间线。
struct RepositoryReleaseDeepLink: Equatable, Hashable, Sendable {
    let repository: RepositoryDeepLink
    let repositoryID: Int64
    let releaseID: Int64

    var owner: String { repository.owner }
    var name: String { repository.name }

    /// Release 深层链接必须同时携带正数 repository ID 与 release ID。
    init?(
        owner: String,
        name: String,
        repositoryID: Int64,
        releaseID: Int64
    ) {
        guard releaseID > 0,
              let repository = RepositoryDeepLink(
                  owner: owner,
                  name: name,
                  repositoryID: repositoryID
              ) else {
            return nil
        }
        self.repository = repository
        self.repositoryID = repositoryID
        self.releaseID = releaseID
    }

    /// 解析受信任的 Universal Link 与 App 内 custom scheme。
    ///
    /// 查询参数采用严格单值规则，避免重复参数由不同解析方取首值或末值后产生歧义。
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let path = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }

        let owner: String
        let name: String
        switch scheme {
        case "https":
            guard url.host?.lowercased() == RepositoryDeepLink.publicHost,
                  path.count == 4,
                  path[0] == "r",
                  path[3] == "releases"
            else { return nil }
            owner = path[1]
            name = path[2]
        case "starcat":
            guard url.host?.lowercased() == "repo",
                  path.count == 3,
                  path[2] == "releases"
            else { return nil }
            owner = path[0]
            name = path[1]
        default:
            return nil
        }

        let queryItems = components.queryItems ?? []
        guard Self.singleValue(named: "v", in: queryItems) == "1",
              let rawRepositoryID = Self.singleValue(named: "rid", in: queryItems),
              let repositoryID = Int64(rawRepositoryID),
              let rawReleaseID = Self.singleValue(named: "release_id", in: queryItems),
              let releaseID = Int64(rawReleaseID)
        else { return nil }

        self.init(
            owner: owner,
            name: name,
            repositoryID: repositoryID,
            releaseID: releaseID
        )
    }

    /// Widget 与其它本机集成使用的唯一 Release URL 形态。
    var appURL: URL {
        var components = URLComponents()
        components.scheme = "starcat"
        components.host = "repo"
        components.path = "/\(owner)/\(name)/releases"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "rid", value: String(repositoryID)),
            URLQueryItem(name: "release_id", value: String(releaseID))
        ]
        return components.url!
    }

    private static func singleValue(
        named name: String,
        in items: [URLQueryItem]
    ) -> String? {
        let matches = items.filter { $0.name == name }
        guard matches.count == 1 else { return nil }
        return matches[0].value
    }
}

private extension UInt8 {
    /// GitHub owner / repo 名称只接受 ASCII 字母与数字；CharacterSet.alphanumerics
    /// 还会接受 Unicode 字母，不能用于协议边界校验。
    var isASCIILetterOrDigit: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }
}
