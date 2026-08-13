//
//  CuratedPublisherModels.swift
//  Starcat
//
//  精选发布台的领域模型：访问策略、GitHub 地址以及 weekly-api 管理员导入契约。
//
//  关键约束：
//  - 客户端 allowlist 只控制运营入口，服务端 admin key 仍是最终认证边界；
//  - 原始线索不能直接发布，必须先收敛为经过 GitHub API 核验的 owner/repo；
//  - Swift DTO 与 weekly-api 的 wire contract 一一对应，避免另造客户端专属协议。
//

import CryptoKit
import Foundation

/// 精选发布台当前访问策略。
///
/// GitHub 数字用户 ID 在 rename 后保持稳定，比 login 更适合做过渡期 allowlist。
/// 后续开放给更多用户时，只替换本策略的来源（例如服务端 role），不要把判断散落到 View。
enum CuratedPublisherAccessPolicy {
    static let allowedGitHubUserIDs: Set<Int64> = [20_341_123]

    static func canAccess(userID: Int64?) -> Bool {
        guard let userID else { return false }
        return allowedGitHubUserIDs.contains(userID)
    }
}

/// 经过语法收敛的 GitHub 仓库地址。
struct GitHubRepositoryAddress: Equatable, Hashable, Sendable {
    let owner: String
    let repo: String

    var normalizedFullName: String { "\(owner)/\(repo)".lowercased() }

    var canonicalURL: URL {
        // owner/repo 已由 ASCII 白名单校验，因此这里构造固定 GitHub URL 不会失败。
        URL(string: "https://github.com/\(owner)/\(repo)")!
    }

    /// 支持完整 GitHub URL 与严格的 `owner/repo` 简写。
    ///
    /// URL 可以带 `.git`、尾斜线或 issues 等仓库子路径；普通简写必须恰好两段，
    /// 防止把任意网页路径误识别成可发布仓库。
    static func parse(_ rawValue: String) -> GitHubRepositoryAddress? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let components = URLComponents(string: value), components.scheme != nil {
            guard let host = components.host?.lowercased(),
                  host == "github.com" || host == "www.github.com"
            else { return nil }
            return parsePath(components.path, allowsSubpath: true)
        }
        return parsePath(value, allowsSubpath: false)
    }

    private static func parsePath(_ rawPath: String, allowsSubpath: Bool) -> GitHubRepositoryAddress? {
        let segments = rawPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 2, allowsSubpath || segments.count == 2 else { return nil }

        let owner = segments[0]
        var repo = segments[1]
        if repo.lowercased().hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard isValidOwner(owner), isValidRepo(repo), !reservedOwners.contains(owner.lowercased()) else {
            return nil
        }
        return GitHubRepositoryAddress(owner: owner, repo: repo)
    }

    private static let reservedOwners: Set<String> = [
        "about", "apps", "collections", "customer-stories", "enterprise", "events", "explore",
        "features", "issues", "marketplace", "new", "notifications", "orgs", "pricing", "search",
        "security", "settings", "sponsors", "topics", "trending", "users"
    ]

    private static func isValidOwner(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 39, !value.hasPrefix("-"), !value.hasSuffix("-") else {
            return false
        }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func isValidRepo(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
        }
    }
}

/// weekly-api 管理端动态来源目录项。
struct CuratedPublisherSource: Decodable, Identifiable, Equatable, Sendable {
    var id: String { code }

    let code: String
    let displayNameZH: String
    let displayNameEN: String
    let iconKey: String
    let sortOrder: Int
    let count: Int
    let ingestMode: String
    let enabled: Bool
    let manualImportEnabled: Bool
    let pending: Int
    let processing: Int
    let retrying: Int
    let discarded: Int

    enum CodingKeys: String, CodingKey {
        case code
        case displayNameZH = "display_name_zh"
        case displayNameEN = "display_name_en"
        case iconKey = "icon_key"
        case sortOrder = "sort_order"
        case count
        case ingestMode = "ingest_mode"
        case enabled
        case manualImportEnabled = "manual_import_enabled"
        case pending, processing, retrying, discarded
    }
}

/// 单仓库人工导入请求。
struct CuratedPublisherImportRequest: Encodable, Equatable, Sendable {
    struct Repository: Encodable, Equatable, Sendable {
        let owner: String
        let repo: String
        let title: String?
        let sourceURL: String?

        enum CodingKeys: String, CodingKey {
            case owner, repo, title
            case sourceURL = "source_url"
        }
    }

    let sourceCode: String
    let idempotencyKey: String
    let repositories: [Repository]

    enum CodingKeys: String, CodingKey {
        case sourceCode = "source_code"
        case idempotencyKey = "idempotency_key"
        case repositories
    }

    /// 同一来源、仓库和原始线索生成稳定键，网络重试不会创建重复事件。
    static func stableIdempotencyKey(
        sourceCode: String,
        address: GitHubRepositoryAddress,
        originalClue: String
    ) -> String {
        let seed = [
            sourceCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            address.normalizedFullName,
            originalClue.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        return "starcat-curated-\(digest)"
    }
}

/// POST `/internal/imports` 的 202 响应。
struct CuratedPublisherBatchAcceptance: Decodable, Equatable, Sendable {
    let batchID: String
    let sourceCode: String
    let status: CuratedPublisherBatchStatus
    let total: Int
    let duplicateCount: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case sourceCode = "source_code"
        case status, total
        case duplicateCount = "duplicate_count"
        case createdAt = "created_at"
    }
}

enum CuratedPublisherBatchStatus: String, Codable, Equatable, Sendable {
    case pending
    case processing
    case success
    case partialSuccess = "partial_success"
    case failed

    var isTerminal: Bool {
        switch self {
        case .success, .partialSuccess, .failed: true
        case .pending, .processing: false
        }
    }
}

struct CuratedPublisherBatchItem: Decodable, Equatable, Sendable {
    let id: Int64
    let owner: String
    let repo: String
    let normalizedFullName: String
    let status: String
    let attempts: Int
    let ghRepoID: Int64?
    let lastErrorCode: String?
    let lastErrorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, owner, repo, status, attempts
        case normalizedFullName = "normalized_full_name"
        case ghRepoID = "gh_repo_id"
        case lastErrorCode = "last_error_code"
        case lastErrorMessage = "last_error_message"
    }
}

/// GET `/internal/imports/{batch_id}` 的完整状态。
struct CuratedPublisherBatch: Decodable, Equatable, Sendable {
    let batchID: String
    let sourceCode: String
    let kind: String
    let idempotencyKey: String?
    let status: CuratedPublisherBatchStatus
    let total: Int
    let success: Int
    let discarded: Int
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let updatedAt: String
    let items: [CuratedPublisherBatchItem]

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case sourceCode = "source_code"
        case kind
        case idempotencyKey = "idempotency_key"
        case status, total, success, discarded
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case updatedAt = "updated_at"
        case items
    }
}
