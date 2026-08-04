//
//  RepositoryReadCapability.swift
//  Starcat
//
//  仓库只读能力的统一执行层。
//
//  Agent 与 MCP 的输入协议不同：Agent 只能读取 run 启动时冻结的仓库快照，MCP 则按
//  starred / knowledge / all 查询实时数据库。本文件只统一领域执行语义，并通过 Source
//  adapter 隔离数据来源；它不依赖 Agent Runtime、MCP SDK、listener、端口或 API Key。
//

import Foundation

enum StarcatCapabilityPermission: String, Codable, Hashable, Sendable {
    case readOnly = "read_only"
    case requiresConfirmation = "requires_confirmation"
}

/// Capability 的稳定业务身份。外部 MCP tool 名和模型可见 Agent tool 名仍由 adapter 维护，
/// 避免内部能力重构意外破坏已经发布的协议。
struct StarcatCapabilityDefinition: Codable, Hashable, Sendable {
    var id: String
    var summary: String
    var permission: StarcatCapabilityPermission
}

enum RepositoryReadCapabilities {
    static let search = StarcatCapabilityDefinition(
        id: "repository.search",
        summary: "Search or list repositories inside the caller-provided scope.",
        permission: .readOnly
    )

    static let get = StarcatCapabilityDefinition(
        id: "repository.get",
        summary: "Resolve one repository by ID or exact owner/name inside the caller-provided scope.",
        permission: .readOnly
    )
}

/// Executor 排序与选择所需的最小仓库表面。
///
/// Core 只为数据库模型声明 conformance；Agent 快照在 Agent 模块自行适配，避免共享能力层
/// 反向依赖某个具体调用方。
protocol RepositoryCapabilityItem: Sendable {
    var id: Int64 { get }
    var owner: String { get }
    var name: String { get }
    var fullName: String { get }
    var starsCount: Int { get }
    var starredAt: String? { get }
}

extension Repo: RepositoryCapabilityItem {}

enum RepositoryCapabilitySort: String, Codable, Hashable, Sendable {
    /// 保留数据源的既有顺序；MCP FTS rank 与 Repository 默认顺序必须使用此模式。
    case sourceOrder = "source_order"
    case starredAt = "starred_at"
    case stars
    case name
}

struct RepositorySearchCapabilityRequest: Sendable {
    var query: String?
    var limit: Int
    var restrictedRepoIDs: [Int64]
    var requiresCompleteRestriction: Bool
    var sort: RepositoryCapabilitySort

    init(
        query: String? = nil,
        limit: Int,
        restrictedRepoIDs: [Int64] = [],
        requiresCompleteRestriction: Bool = false,
        sort: RepositoryCapabilitySort = .sourceOrder
    ) {
        self.query = query
        self.limit = max(1, limit)
        self.restrictedRepoIDs = restrictedRepoIDs
        self.requiresCompleteRestriction = requiresCompleteRestriction
        self.sort = sort
    }
}

struct RepositorySearchCapabilityResult<Item: RepositoryCapabilityItem>: Sendable {
    var query: String?
    var total: Int
    var limit: Int
    var repositories: [Item]
}

struct RepositoryCapabilitySelector: Hashable, Sendable {
    var repoID: Int64?
    var owner: String?
    var name: String?

    init(repoID: Int64? = nil, owner: String? = nil, name: String? = nil) {
        self.repoID = repoID
        // Adapter 负责输入规范；能力层保留调用方原值，避免迁移时改变 MCP 已发布的
        // “精确 owner/name”与 Agent “精确 fullName”匹配行为。
        self.owner = owner
        self.name = name
    }

    init(repoID: Int64? = nil, fullName: String?) {
        self.repoID = repoID
        let parts = fullName?
            .split(separator: "/", maxSplits: 1)
            .map(String.init) ?? []
        owner = parts.count == 2 ? parts[0] : nil
        name = parts.count == 2 ? parts[1] : nil
    }

    var displayValue: String {
        if let repoID { return String(repoID) }
        if let owner, let name, !owner.isEmpty, !name.isEmpty { return "\(owner)/\(name)" }
        return "missing"
    }
}

/// 数据来源 adapter。Source 决定“可见范围”，Executor 只在该范围内查询，不能自行扩大。
protocol RepositoryReadCapabilitySource: Sendable {
    associatedtype Item: RepositoryCapabilityItem

    func list() async throws -> [Item]
    func search(query: String) async throws -> [Item]
    func findByID(_ repoID: Int64) async throws -> Item?
    func findByOwnerName(owner: String, name: String) async throws -> Item?
}

/// 仓库只读能力的唯一业务执行器。
///
/// `requiresCompleteRestriction` 是 Agent 的 fail-closed 开关：模型传入任何冻结范围外 ID，
/// 整次调用必须失败，不能静默忽略后继续生成看似完整的报告。MCP 没有该额外约束。
struct RepositoryReadCapabilityExecutor<Source: RepositoryReadCapabilitySource>: Sendable {
    let source: Source

    func search(_ request: RepositorySearchCapabilityRequest) async throws -> RepositorySearchCapabilityResult<Source.Item> {
        let normalizedQuery = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceItems = normalizedQuery.isEmpty
            ? try await source.list()
            : try await source.search(query: normalizedQuery)
        let restrictedIDs = Set(request.restrictedRepoIDs)
        if request.requiresCompleteRestriction, !restrictedIDs.isEmpty {
            let availableIDs = Set(sourceItems.map(\.id))
            let unknownIDs = restrictedIDs.subtracting(availableIDs).sorted()
            guard unknownIDs.isEmpty else {
                throw RepositoryReadCapabilityError.repositoriesOutsideScope(unknownIDs)
            }
        }
        let scopedItems = restrictedIDs.isEmpty
            ? sourceItems
            : sourceItems.filter { restrictedIDs.contains($0.id) }
        let orderedItems = order(scopedItems, by: request.sort)
        return RepositorySearchCapabilityResult(
            query: normalizedQuery.isEmpty ? nil : normalizedQuery,
            total: orderedItems.count,
            limit: request.limit,
            repositories: Array(orderedItems.prefix(request.limit))
        )
    }

    func get(_ selector: RepositoryCapabilitySelector) async throws -> Source.Item {
        if let repoID = selector.repoID {
            guard let item = try await source.findByID(repoID) else {
                throw RepositoryReadCapabilityError.notFound(selector.displayValue)
            }
            return item
        }
        guard let owner = selector.owner,
              let name = selector.name,
              !owner.isEmpty,
              !name.isEmpty
        else {
            throw RepositoryReadCapabilityError.invalidSelector
        }
        guard let item = try await source.findByOwnerName(owner: owner, name: name) else {
            throw RepositoryReadCapabilityError.notFound(selector.displayValue)
        }
        return item
    }

    private func order(_ items: [Source.Item], by sort: RepositoryCapabilitySort) -> [Source.Item] {
        guard sort != .sourceOrder else { return items }
        return items.sorted { lhs, rhs in
            switch sort {
            case .sourceOrder:
                return false
            case .starredAt:
                let lhsDate = lhs.starredAt ?? ""
                let rhsDate = rhs.starredAt ?? ""
                if lhsDate != rhsDate { return lhsDate > rhsDate }
            case .stars:
                if lhs.starsCount != rhs.starsCount { return lhs.starsCount > rhs.starsCount }
            case .name:
                break
            }
            return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
        }
    }
}

enum RepositoryReadCapabilityError: LocalizedError, Equatable, Sendable {
    case invalidSelector
    case notFound(String)
    case repositoriesOutsideScope([Int64])

    var errorDescription: String? {
        switch self {
        case .invalidSelector:
            return "Provide repository ID or owner + name."
        case .notFound(let selector):
            return "Repository not found: \(selector)"
        case .repositoriesOutsideScope(let repoIDs):
            return "Repository IDs are outside the allowed scope: \(repoIDs.map(String.init).joined(separator: ", "))"
        }
    }
}

/// MCP / App 内部数据库入口。scope 在 adapter 创建时冻结，单次执行不能中途切换。
struct DatabaseRepositoryReadCapabilitySource: RepositoryReadCapabilitySource {
    let repository: any RepoRepositoryProtocol
    let scope: SemanticIndexScope

    func list() async throws -> [Repo] {
        switch scope {
        case .starred:
            let starred = try await repository.fetchAllStarred()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: [])
        case .knowledge:
            let knowledge = try await repository.fetchKnowledgeRepos()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: [], knowledge: knowledge)
        case .all:
            let starred = try await repository.fetchAllStarred()
            let knowledge = try await repository.fetchKnowledgeRepos()
            return SemanticIndexScope.selectCandidates(
                scope: scope,
                starred: starred,
                knowledge: knowledge
            )
        }
    }

    func search(query: String) async throws -> [Repo] {
        switch scope {
        case .starred:
            return try await repository.searchFTS(query: query)
        case .knowledge:
            return try await repository.searchKnowledgeFTS(query: query)
        case .all:
            let starred = try await repository.searchFTS(query: query)
            let knowledge = try await repository.searchKnowledgeFTS(query: query)
            return SemanticIndexScope.selectCandidates(
                scope: scope,
                starred: starred,
                knowledge: knowledge
            )
        }
    }

    func findByID(_ repoID: Int64) async throws -> Repo? {
        try await repository.findById(repoID)
    }

    func findByOwnerName(owner: String, name: String) async throws -> Repo? {
        try await repository.findByOwnerName(owner: owner, name: name)
    }
}
