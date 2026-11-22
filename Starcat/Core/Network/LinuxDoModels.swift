//
//  LinuxDoModels.swift
//  Starcat
//
//  Linux.do 公共目录与来源证据契约。来源不是用户标签，也不触发 Star 或入库。
//

import Foundation

/// 来源是 Discovery 内独立的筛选轴，不能伪装成 GitHub topic。
enum DiscoverySource: String, Sendable { case catalog, linuxDo }

enum LinuxDoResource: Hashable, Sendable {
    case catalog, provenance, topics(Int64)

    var path: String {
        switch self {
        case .catalog: return "api/v1/discovery/linuxdo/bulk"
        case .provenance: return "api/v1/discovery/linuxdo/provenance"
        case .topics(let id): return "api/v1/discovery/linuxdo/repos/\(id)/topics"
        }
    }
}

struct LinuxDoOrigin: Codable, Equatable, Sendable {
    let repoID: Int64
    let topicCount: Int
    let verifiedAt: String
    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id", topicCount = "topic_count", verifiedAt = "verified_at"
    }
}

struct LinuxDoTopic: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let url: String
    let title: String
    let publishedAt: String
    let verifiedAt: String

    /// 不信任远端 URL：来源回链只允许固定 Linux.do HTTPS 首帖地址。
    var safeURL: URL? {
        guard id > 0, url == "https://linux.do/t/topic/\(id)" else { return nil }
        return URL(string: url)
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, publishedAt = "published_at", verifiedAt = "verified_at"
    }
}

/// 三个端点共用发布版本，但分别验证必需字段，不能把缺失数组解释为清空。
struct LinuxDoPayload: Codable, Sendable {
    let revision: Int64
    let generatedAt: String
    let complete: Bool
    var repositories: [DiscoveryRepoDTO]?
    var promotionDates: [String: String]?
    var origins: [LinuxDoOrigin]?
    var topics: [LinuxDoTopic]?
    var repoID: Int64?

    enum CodingKeys: String, CodingKey {
        case revision, complete, repositories, origins, topics
        case generatedAt = "generated_at", repoID = "repo_id"
        case promotionDates = "promotion_dates"
    }

    /// 网络层先拒绝不完整的发布。只有需要入库的新版本才逐条验证和解析。
    func validateStructure(for resource: LinuxDoResource) throws {
        guard complete, revision >= 0 else { throw LinuxDoCacheError.invalidSnapshot }
        switch resource {
        case .catalog:
            guard repositories != nil, promotionDates != nil else { throw LinuxDoCacheError.invalidSnapshot }
        case .provenance:
            guard origins != nil else { throw LinuxDoCacheError.invalidSnapshot }
        case .topics(let id):
            guard repoID == id, topics != nil else { throw LinuxDoCacheError.invalidSnapshot }
        }
    }

    func validate(for resource: LinuxDoResource) throws {
        try validateStructure(for: resource)
        let timestamp = LinuxDoTimestampParser()
        switch resource {
        case .catalog:
            guard let repositories, let promotionDates,
                  repositories.allSatisfy({ $0.repoID > 0 && !$0.fullName.isEmpty && timestamp.parse(promotionDates[String($0.repoID)]) != nil }),
                  Set(repositories.map(\.repoID)).count == repositories.count else { throw LinuxDoCacheError.invalidSnapshot }
        case .provenance:
            guard let origins, origins.allSatisfy({ $0.repoID > 0 && $0.topicCount > 0 && timestamp.parse($0.verifiedAt) != nil }),
                  Set(origins.map(\.repoID)).count == origins.count else { throw LinuxDoCacheError.invalidSnapshot }
        case .topics(let id):
            guard repoID == id, let topics, topics.allSatisfy({ $0.safeURL != nil && !$0.title.isEmpty }),
                  Set(topics.map(\.id)).count == topics.count else { throw LinuxDoCacheError.invalidSnapshot }
        }
    }

    /// Go 的 RFC3339 快照通常不带小数秒；复用双格式解析，避免拒绝有效目录和来源索引。
    static func date(_ value: String) -> Date? {
        ISO8601DateFormatter.githubDate(from: value)
    }
}

/// 仅在同一批次内复用 formatter。生产时间戳有两种精度，逐条创建 formatter 会放大导入成本。
struct LinuxDoTimestampParser {
    private let fractional = ISO8601DateFormatter.shared
    private let wholeSeconds = ISO8601DateFormatter()

    func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return fractional.date(from: value) ?? wholeSeconds.date(from: value)
    }
}

enum LinuxDoCacheError: Error { case invalidSnapshot, missingCachedBody, obsoleteRevision }

struct LinuxDoResponse: Sendable {
    /// nil 只表示经过验证的 304，不能用作错误降级。
    let payload: LinuxDoPayload?
    let etag: String?
}

/// 旧版 JSON 的迁移契约；checkedAt 是 HTTP 校验时间，不是帖子的核验日期。
struct LinuxDoCachedSnapshot: Codable, Sendable {
    let providerID: String
    let payload: LinuxDoPayload
    let etag: String?
    let checkedAt: Date
}

protocol LinuxDoAPIProtocol: Sendable {
    func linuxDoProviderIdentity() async -> String
    func fetchLinuxDo(_ resource: LinuxDoResource, providerID: String, ifNoneMatch: String?) async throws -> LinuxDoResponse
}

extension DiscoveryAPI: LinuxDoAPIProtocol {}
