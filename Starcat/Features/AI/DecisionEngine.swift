//
//  DecisionEngine.swift
//  Starcat
//
//  实验性决策引擎的稳定边界。
//
//  业务层只描述「状态 + 类型化问题」，具体由 Jev 远端 API 或 Laya 本地 MLX
//  实现回答。注册表按用户显式选择返回唯一实现，不在引擎之间做隐式故障切换；
//  这样一次业务动作不会因为瞬时错误重复计费，也不会悄悄改变决策模型语义。
//

import Foundation

/// 可供用户选择的决策引擎标识。
///
/// 新增实现时只需增加枚举项、实现 `DecisionEngineProviding` 并在装配层注册，
/// 仓库分组与标签建议逻辑不需要认识具体 runtime。
enum DecisionEngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case jev
    case laya

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jev:
            return "Jev"
        case .laya:
            return "Laya"
        }
    }

    var tagSuggestionEngine: AITagSuggestionEngine {
        switch self {
        case .jev:
            return .jev
        case .laya:
            return .laya
        }
    }
}

/// 决策问题的 instructions 可为普通文本或结构化键值。
///
/// 结构化形式用于隔离固定问题和用户配置，避免 List 规则中的引号或换行改变问题边界。
enum DecisionQuestionInstructions: Encodable, Equatable, Sendable, ExpressibleByStringLiteral {
    case text(String)
    case object([String: String])

    init(stringLiteral value: String) {
        self = .text(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// Laya 接收文本 prompt；对象按 key 排序，保证同一问题跨运行生成相同输入。
    var localPromptText: String {
        switch self {
        case .text(let value):
            return value
        case .object(let value):
            return value.keys.sorted().map { key in
                "\(key): \(value[key] ?? "")"
            }.joined(separator: "\n")
        }
    }
}

/// Noul true / false 的显式判据。
struct DecisionNoulCriteria: Encodable, Equatable, Sendable {
    var `true`: String?
    var `false`: String?
}

/// 当前决策抽象只开放业务实际使用的 Noul 原语。
struct DecisionNoulQuestion: Encodable, Equatable, Sendable {
    let instructions: DecisionQuestionInstructions
    let criteria: DecisionNoulCriteria?

    /// Laya 没有结构化 criteria 参数，因此把判据追加到问题文本；字段名固定，
    /// 既保留概率语义，也避免调用方各自拼 prompt。
    var localPromptText: String {
        var parts = [instructions.localPromptText]
        if let trueCriterion = criteria?.true, !trueCriterion.isEmpty {
            parts.append("true criterion: \(trueCriterion)")
        }
        if let falseCriterion = criteria?.false, !falseCriterion.isEmpty {
            parts.append("false criterion: \(falseCriterion)")
        }
        return parts.joined(separator: "\n")
    }
}

/// 仓库分类所需的最小事实快照。
///
/// README 是不可信数据，只作为 state 传入；候选过滤、封闭集校验与最终写入仍在代码层。
struct RepositoryDecisionState: Encodable, Equatable, Sendable {
    struct RepositoryFacts: Encodable, Equatable, Sendable {
        let fullName: String
        let description: String?
        let language: String?
        let topics: [String]
        let starsCount: Int
        let forksCount: Int
        let isArchived: Bool
        let isPrivate: Bool
    }

    let repository: RepositoryFacts
    let readmeExcerpt: String
    let existingListNames: [String]
    let existingTags: [String]

    init(repo: Repo, readmeExcerpt: String, existingListNames: [String], existingTags: [String]) {
        repository = RepositoryFacts(
            fullName: repo.fullName,
            description: repo.description,
            language: repo.language,
            topics: repo.topicsArray,
            starsCount: repo.starsCount,
            forksCount: repo.forksCount,
            isArchived: repo.isArchived,
            isPrivate: repo.isPrivate
        )
        self.readmeExcerpt = readmeExcerpt
        self.existingListNames = existingListNames
        self.existingTags = existingTags
    }

    /// 本地模型使用稳定的纯文本快照，避免依赖 JSON key 顺序或把 README 当作指令。
    var localPromptText: String {
        [
            "repository.fullName: \(repository.fullName)",
            "repository.description: \(repository.description ?? "")",
            "repository.language: \(repository.language ?? "")",
            "repository.topics: \(repository.topics.joined(separator: ", "))",
            "repository.starsCount: \(repository.starsCount)",
            "repository.forksCount: \(repository.forksCount)",
            "repository.isArchived: \(repository.isArchived)",
            "repository.isPrivate: \(repository.isPrivate)",
            "existingListNames: \(existingListNames.joined(separator: ", "))",
            "existingTags: \(existingTags.joined(separator: ", "))",
            "readmeExcerpt:\n\(readmeExcerpt)",
        ].joined(separator: "\n")
    }
}

/// 引擎无关的 state。连接测试用短文本，真实业务使用结构化仓库快照。
enum DecisionState: Encodable, Equatable, Sendable {
    case text(String)
    case repository(RepositoryDecisionState)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .repository(let value):
            try container.encode(value)
        }
    }

    var localPromptText: String {
        switch self {
        case .text(let value):
            return value
        case .repository(let value):
            return value.localPromptText
        }
    }
}

/// 固定业务维度只用于聚合诊断，不允许把用户输入写入日志维度。
enum DecisionEvaluationOperation: String, Sendable {
    case unspecified
    case githubListGrouping = "github_list_grouping"
    case tagReuse = "tag_reuse"
    case connectionTest = "connection_test"
    case searchIntent = "search_intent"
}

struct DecisionEvaluationRequest: Equatable, Sendable {
    let state: DecisionState
    let questions: [String: DecisionNoulQuestion]
    let operation: DecisionEvaluationOperation
}

struct DecisionNoulAnswer: Equatable, Sendable {
    let probability: Double
}

struct DecisionEvaluationResponse: Equatable, Sendable {
    let answers: [String: DecisionNoulAnswer]
}

/// 同步可查询的可用性只决定「是否在调用前回退既有 LLM」。
/// 一旦引擎调用已经开始，运行时错误必须上抛，不能再偷偷切换另一引擎或双跑 LLM。
enum DecisionEngineAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// 一个结构化决策引擎实现。
@MainActor
protocol DecisionEngineProviding: AnyObject, Sendable {
    var id: DecisionEngineID { get }
    var availability: DecisionEngineAvailability { get }

    func evaluate(_ request: DecisionEvaluationRequest) async throws -> DecisionEvaluationResponse
}

/// 进程级引擎注册表。
///
/// 使用协议 existential 是有意的：这里确实需要在同一个集合中持有异构的 Jev/Laya
/// 实现；业务热路径拿到具体实例后只调用一次，不引入额外类型擦除层。
@MainActor
final class DecisionEngineRegistry {
    private let engines: [DecisionEngineID: any DecisionEngineProviding]

    init(engines: [any DecisionEngineProviding]) {
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
    }

    func engine(for id: DecisionEngineID) -> (any DecisionEngineProviding)? {
        engines[id]
    }
}
