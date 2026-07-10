//
//  AgentPromptBuilder.swift
//  Starcat
//
//  Agent system prompt、每轮请求和上下文预算的单一构建入口。
//
//  Prompt 不再按具体 Agent 散落硬编码。Runtime 传入环境、产品规则、当前可见工具和冻结
//  上下文，Builder 生成稳定的 system/turn 请求；测试可直接注入日期与 locale，避免依赖机器状态。
//

import Foundation

enum AgentExecutionMode: String, Codable, Hashable, Sendable {
    case readonlyPlanning
    case reportGeneration
    case approvedAction
    case backgroundDigest
}

struct AgentPromptEnvironment: Codable, Hashable, Sendable {
    var appName: String
    var appVersion: String
    var platform: String
    var currentDate: Date
    var localeIdentifier: String
    var workspaceName: String
    var mode: AgentExecutionMode

    static func current(
        mode: AgentExecutionMode,
        locale: Locale,
        workspaceName: String = "Starcat Knowledge Library"
    ) -> AgentPromptEnvironment {
        AgentPromptEnvironment(
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Starcat",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            currentDate: Date(),
            localeIdentifier: locale.identifier,
            workspaceName: workspaceName,
            mode: mode
        )
    }
}

struct AgentPromptRule: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var content: String
}

/// Prompt 只需要模型可读摘要；完整 JSON Schema 由模型请求的 tools 字段承载。
struct AgentPromptToolSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var description: String
    var permission: AgentToolPermission
}

struct AgentExternalSearchPolicy: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var provider: String
    var allowsPrivateRepositories: Bool
    var aggregatesProviders: Bool

    var privacyBoundary: String {
        if allowsPrivateRepositories {
            return "Private repository search is allowed only when the existing Starcat setting and provider support it."
        }
        return "Do not send private repository metadata or content to external search providers."
    }

    @MainActor
    static func current(settings: AppSettings) -> AgentExternalSearchPolicy {
        AgentExternalSearchPolicy(
            isEnabled: settings.externalContextEnabled,
            provider: settings.externalContextProviderSelection.rawValue,
            allowsPrivateRepositories: settings.externalSearchAllowPrivateRepos,
            aggregatesProviders: settings.aggregateExternalContextSearchEnabled && settings.isProUser
        )
    }
}

struct AgentPromptContext: Hashable, Sendable {
    var definition: AgentDefinition
    var runContext: AgentRunContext
    var availableTools: [AgentPromptToolSummary]
    var rules: [AgentPromptRule]
    var preferredLanguage: String
    var externalSearch: AgentExternalSearchPolicy
}

struct AgentPromptTurnRequest: Hashable, Sendable {
    var systemPrompt: String
    var userPrompt: String
    var messages: [AgentMessage]
}

protocol AgentPromptBuilding: Sendable {
    func buildSystemPrompt(environment: AgentPromptEnvironment, context: AgentPromptContext) -> String
    func buildTurnRequest(
        userInput: String,
        messages: [AgentMessage],
        environment: AgentPromptEnvironment,
        context: AgentPromptContext
    ) -> AgentPromptTurnRequest
}

/// Starcat Agent Prompt Pipeline 的默认实现。
struct AgentPromptBuilder: AgentPromptBuilding {
    private let budgeter: AgentContextBudgeter
    private let compactor: AgentMessageCompactor

    init(
        budgeter: AgentContextBudgeter = AgentContextBudgeter(),
        compactor: AgentMessageCompactor = AgentMessageCompactor()
    ) {
        self.budgeter = budgeter
        self.compactor = compactor
    }

    func buildSystemPrompt(environment: AgentPromptEnvironment, context: AgentPromptContext) -> String {
        let toolLines = context.availableTools.isEmpty
            ? "- No tools are available in this mode."
            : context.availableTools.map {
                "- \($0.name) [\($0.permission.rawValue)]: \($0.description)"
            }.joined(separator: "\n")
        let ruleLines = context.rules.isEmpty
            ? "- Follow the built-in product boundaries below."
            : context.rules.map { "- [\($0.id)] \($0.content)" }.joined(separator: "\n")

        return """
        You are Starcat's \(context.definition.title) Agent for a local-first GitHub Star knowledge library.

        # Environment
        - app: \(environment.appName) \(environment.appVersion)
        - platform: \(environment.platform)
        - current_date: \(ISO8601DateFormatter.shared.string(from: environment.currentDate))
        - locale: \(environment.localeIdentifier)
        - workspace: \(environment.workspaceName)
        - execution_mode: \(environment.mode.rawValue)

        # Product Boundaries
        - Use only the real local Starcat snapshot and explicit tool results. Never invent repositories, sources, or completed actions.
        - Default to read-only behavior. A write-capable tool must be approved by the user before the host executes it.
        - Keep tool-call arguments minimal and valid for the provided schema.
        - If a tool fails, is skipped, times out, or is rejected, use that tool-result honestly and continue only when useful.
        - Produce user-facing text in \(context.preferredLanguage) unless the user explicitly requests another language.

        # Mode Guardrails
        \(modeInstructions(environment.mode))

        # External Search
        - enabled: \(context.externalSearch.isEnabled)
        - provider_selection: \(context.externalSearch.provider)
        - aggregate_providers: \(context.externalSearch.aggregatesProviders)
        - privacy: \(context.externalSearch.privacyBoundary)
        - When disabled, do not claim external research; use the skipped tool-result and local context.

        # Visible Tools
        \(toolLines)

        # Rules
        \(ruleLines)
        """
    }

    func buildTurnRequest(
        userInput: String,
        messages: [AgentMessage],
        environment: AgentPromptEnvironment,
        context: AgentPromptContext
    ) -> AgentPromptTurnRequest {
        let boundedRepos = budgeter.repositorySnapshotBlock(context.runContext)
        let compactedMessages = compactor.compact(messages)
        let prompt = messages.isEmpty ? """
        # User Goal
        \(budgeter.bounded(userInput, limit: budgeter.budget.maxUserInputCharacters))

        # Frozen Starcat Context
        source: \(context.runContext.sourceDescription)
        generated_at: \(ISO8601DateFormatter.shared.string(from: context.runContext.generatedAt))
        repositories:
        \(boundedRepos)

        Select tools only when they materially advance the goal. Return a final answer only after required evidence is available.
        """ : ""
        return AgentPromptTurnRequest(
            systemPrompt: buildSystemPrompt(environment: environment, context: context),
            userPrompt: prompt,
            messages: compactedMessages
        )
    }

    private func modeInstructions(_ mode: AgentExecutionMode) -> String {
        switch mode {
        case .readonlyPlanning:
            return "Plan and inspect only. Do not request write-capable tools or claim that data was changed."
        case .reportGeneration:
            return "Gather evidence with read-only tools, then submit one auditable report artifact in execution order."
        case .approvedAction:
            return "Read-only tools may run automatically. Every write-capable tool-call must wait for explicit user approval."
        case .backgroundDigest:
            return "Use read-only tools only, respect strict budgets, and never prompt for or perform writes in the background."
        }
    }
}

struct AgentContextBudget: Hashable, Sendable {
    var maxRepositories = 40
    var maxRepositoryDescriptionCharacters = 400
    var maxUserInputCharacters = 4_000
    var maxExternalContextCharacters = 8_000
    var maxToolResultCharacters = 8_000
    var maxMessageCharacters = 24_000
}

/// 对进入模型上下文的文本做确定性裁剪，完整原文仍由工具结果或 artifact 持久化。
struct AgentContextBudgeter: Sendable {
    let budget: AgentContextBudget

    init(budget: AgentContextBudget = AgentContextBudget()) {
        self.budget = budget
    }

    func repositorySnapshotBlock(_ context: AgentRunContext) -> String {
        let repos = context.repos.prefix(max(0, budget.maxRepositories))
        guard !repos.isEmpty else { return "- none" }
        let lines = repos.map { repo in
            let description = bounded(repo.description ?? "", limit: budget.maxRepositoryDescriptionCharacters)
            return "- id=\(repo.id) | full_name=\(repo.fullName) | private=\(repo.isPrivate) | language=\(repo.language ?? "Unknown") | stars=\(repo.starsCount) | topics=\(repo.topics.joined(separator: ",")) | description=\(description)"
        }
        let omitted = max(0, context.repos.count - repos.count)
        return omitted == 0
            ? lines.joined(separator: "\n")
            : lines.joined(separator: "\n") + "\n- [\(omitted) repositories omitted by context budget]"
    }

    func bounded(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return limit > 0 ? text : "" }
        let marker = "\n[truncated by Agent context budget]"
        return String(text.prefix(max(0, limit - marker.count))) + marker
    }
}

/// 长 run 只保留首个用户目标和最近的完整 turn，tool-call/tool-result 不拆开裁剪。
struct AgentMessageCompactor: Sendable {
    private let maxCharacters: Int

    init(maxCharacters: Int = AgentContextBudget().maxMessageCharacters) {
        self.maxCharacters = maxCharacters
    }

    func compact(_ messages: [AgentMessage]) -> [AgentMessage] {
        guard estimatedCharacters(messages) > maxCharacters, let first = messages.first else { return messages }
        let groups = Dictionary(grouping: messages, by: \.turn)
            .sorted { $0.key < $1.key }
            .map(\.value)
        var selected: [AgentMessage] = [first]
        var used = estimatedCharacters(selected)

        for group in groups.reversed() {
            let candidates = group.filter { $0.id != first.id }
            guard !candidates.isEmpty else { continue }
            let size = estimatedCharacters(candidates)
            if used + size <= maxCharacters {
                selected.append(contentsOf: candidates)
                used += size
            }
        }
        return Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            .values
            .sorted { $0.sequence < $1.sequence }
    }

    private func estimatedCharacters(_ messages: [AgentMessage]) -> Int {
        guard let data = try? JSONEncoder().encode(messages) else {
            return messages.count * 1_000
        }
        return data.count
    }
}
