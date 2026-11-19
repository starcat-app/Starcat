//
//  SkillEvaluationReportPresentation.swift
//  Starcat
//
//  将报告快照中的技术标识与已知 Starcat 模板转为展示数据。缓存与导出仍使用原始证据。
//

import Foundation

/// v1.0.1 的六种内容规则按固定顺序展示。报告缺行时无法推断该 Agent 的结论。
enum SkillEvaluationHarnessAgent: String, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case copilotCLI = "copilot-cli"
    case hermes
    case openClaw = "openclaw"
    case openCode = "opencode"

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .copilotCLI: "Copilot CLI"
        case .hermes: "Hermes"
        case .openClaw: "OpenClaw"
        case .openCode: "OpenCode"
        }
    }
}

/// 展示态区分无记录与无法消歧的记录，避免把任何一个缺口显示成通过。
struct SkillEvaluationHarnessRow: Identifiable {
    enum Status: Equatable {
        case reported(SkillEvaluationHarnessProfile.Status)
        case missing
        case unknown
    }

    let id: String
    let agent: SkillEvaluationHarnessAgent?
    let status: Status
    let rules: [String]

    /// 缺失、重复或陌生 ID 不参与推断。保留读到的规则号，供核对缓存或导出报告。
    static func rows(for profiles: [SkillEvaluationHarnessProfile]?) -> [Self] {
        let grouped = Dictionary(grouping: profiles ?? [], by: \.id)
        let known = SkillEvaluationHarnessAgent.allCases.map { agent in
            let profiles = grouped[agent.rawValue, default: []]
            let status: Status = switch profiles.count {
            case 0: .missing
            case 1: .reported(profiles[0].status)
            default: .unknown
            }
            return Self(id: agent.rawValue, agent: agent, status: status, rules: profiles.flatMap(\.rules))
        }
        let unknown = grouped.keys.sorted().filter { SkillEvaluationHarnessAgent(rawValue: $0) == nil }
        return known + unknown.map { id in
            Self(id: id, agent: nil, status: .unknown, rules: grouped[id, default: []].flatMap(\.rules))
        }
    }
}

/// 旧快照只有 `details: [String]`。按检查 ID 匹配完整模板，模板变化时回退到原始证据。
enum SkillEvaluationReportLine: Equatable {
    enum Term: String {
        case checkAbsent = "skills.evaluation.detail.checkAbsent"
        case coverageIncomplete = "skills.evaluation.detail.coverageIncomplete"
        case sourceHierarchy = "skills.evaluation.detail.sourceHierarchy"
        case schemaFinding = "skills.evaluation.detail.schemaFinding"
        case englishHeuristics = "skills.evaluation.detail.englishHeuristics"
        case harnessScope = "skills.evaluation.harness.scope"
        case harnessCoverage = "skills.evaluation.harness.coverage"
        case securityScope = "skills.evaluation.detail.securityScope"
        case securityFinding = "skills.evaluation.detail.securityFinding"
        case findingCount = "skills.evaluation.detail.findingCount"
        case rubricIncomplete = "skills.evaluation.detail.rubricIncomplete"
        case duplicateContent = "skills.evaluation.detail.duplicateContent"
        case insufficientText = "skills.evaluation.detail.insufficientText"
        case textFiles = "skills.evaluation.detail.textFiles"
        case chunks = "skills.evaluation.detail.chunks"
        case clustersToReview = "skills.evaluation.detail.clustersToReview"
        case reviewedClusters = "skills.evaluation.detail.reviewedClusters"
        case descriptionComparison = "skills.evaluation.detail.descriptionComparison"
        case indexedSkills = "skills.evaluation.detail.indexedSkills"
        case correctness = "skills.evaluation.dimension.correctness"
        case discoverability = "skills.evaluation.dimension.discoverability"
        case reliability = "skills.evaluation.dimension.reliability"
        case efficiency = "skills.evaluation.dimension.efficiency"
        case descriptionClarity = "skills.evaluation.criterion.descriptionClarity"
        case instructionClarity = "skills.evaluation.criterion.instructionClarity"
        case exampleQuality = "skills.evaluation.criterion.exampleQuality"
        case documentationCompleteness = "skills.evaluation.criterion.documentationCompleteness"
        case scopeDefinition = "skills.evaluation.criterion.scopeDefinition"
        case professionalTone = "skills.evaluation.criterion.professionalTone"
        case triggerSimulation = "skills.evaluation.criterion.triggerSimulation"
        case workflowCompleteness = "skills.evaluation.criterion.workflowCompleteness"
        case errorHandlingQuality = "skills.evaluation.criterion.errorHandlingQuality"
    }

    enum Severity: String {
        case critical, high, medium, low, info
    }

    enum FindingLabel: Equatable {
        case term(Term)
        case rule(String)
    }

    struct Location: Equatable {
        enum File: Equatable {
            case manifest
            case attachment(Int)
        }

        let file: File
        let line: Int?
    }

    case note(Term)
    case metric(Term, String)
    case pair(Int, Int, score: String)
    case finding(FindingLabel, Severity?, [Location])
    case original(String)

    /// 数值保留快照精度。只识别本版本 Parser 写出的固定说明与位置语法。
    init(checkID: String, raw: String) {
        let line: Self? = switch (checkID, raw) {
        case (_, "Check absent from report"): .note(.checkAbsent)
        case (_, "Check coverage incomplete"): .note(.coverageIncomplete)
        case ("schema", "Source hierarchy unavailable from snapshot"): .note(.sourceHierarchy)
        case ("quality", "Static scoring includes English-language heuristics"): .note(.englishHeuristics)
        case ("harness", "Static profiles only; installation location and other agents are outside scope"): .note(.harnessScope)
        case ("harness", "Agent profile coverage incomplete"): .note(.harnessCoverage)
        case ("security", "SkillSpector static scan"): .note(.securityScope)
        case ("rubric", "Rubric response incomplete"): .note(.rubricIncomplete)
        case ("context-optimization", "Insufficient text for comparison"): .note(.insufficientText)
        case ("similarity", "Description comparison"): .note(.descriptionComparison)
        default: Self.metric(checkID: checkID, raw: raw)
            ?? Self.pair(checkID: checkID, raw: raw)
            ?? Self.finding(checkID: checkID, raw: raw)
        }
        self = line ?? .original(raw)
    }

    private static func metric(checkID: String, raw: String) -> Self? {
        guard let match = raw.wholeMatch(of: #/([A-Za-z_ ]+) ((-?[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?)(?:\/(-?[0-9]+))?)/#) else {
            return nil
        }
        let (_, label, value, numerator, denominator) = match.output
        let integer = Int(numerator) != nil
        let term: Term? = switch (checkID, label) {
        case ("quality", "correctness") where denominator == "100": .correctness
        case ("quality", "discoverability") where denominator == "100": .discoverability
        case ("quality", "reliability") where denominator == "100": .reliability
        case ("quality", "efficiency") where denominator == "100": .efficiency
        case ("rubric", "description_clarity") where integer && denominator == "10": .descriptionClarity
        case ("rubric", "instruction_clarity") where integer && denominator == "10": .instructionClarity
        case ("rubric", "example_quality") where integer && denominator == "10": .exampleQuality
        case ("rubric", "documentation_completeness") where integer && denominator == "10": .documentationCompleteness
        case ("rubric", "scope_definition") where integer && denominator == "10": .scopeDefinition
        case ("rubric", "professional_tone") where integer && denominator == "10": .professionalTone
        case ("rubric", "trigger_simulation") where integer && denominator == "10": .triggerSimulation
        case ("rubric", "workflow_completeness") where integer && denominator == "10": .workflowCompleteness
        case ("rubric", "error_handling_quality") where integer && denominator == "10": .errorHandlingQuality
        case ("security", "Findings") where integer && denominator == nil: .findingCount
        case ("context-optimization", "Text files") where integer && denominator == nil: .textFiles
        case ("context-optimization", "Chunks") where integer && denominator == nil: .chunks
        case ("context-optimization", "Clusters requiring review") where integer && denominator == nil: .clustersToReview
        case ("context-optimization", "Reviewed clusters") where integer && denominator != nil: .reviewedClusters
        case ("similarity", "Indexed skills") where integer && denominator != nil: .indexedSkills
        default: nil
        }
        return term.map { .metric($0, String(value)) }
    }

    private static func pair(checkID: String, raw: String) -> Self? {
        guard checkID == "similarity",
              let match = raw.wholeMatch(of: #/Items ([1-9][0-9]*) and ([1-9][0-9]*) \(([0-9]+(?:\.[0-9]+)?)\)/#),
              let first = Int(match.1), let second = Int(match.2) else { return nil }
        return .pair(first, second, score: String(match.3))
    }

    private static func finding(checkID: String, raw: String) -> Self? {
        guard ["schema", "security", "context-optimization"].contains(checkID),
              let match = raw.wholeMatch(of: #/([A-Za-z0-9_ ]+?)(?: \((critical|high|medium|low|info)\))?(?: · (.+))?/#)
        else { return nil }
        let (_, name, risk, position) = match.output
        let label: FindingLabel
        switch (checkID, name) {
        case ("schema", "Schema finding"): label = .term(.schemaFinding)
        case ("security", "Security finding"): label = .term(.securityFinding)
        case ("context-optimization", "Duplicate content"): label = .term(.duplicateContent)
        case ("schema", _) where name.wholeMatch(of: #/[a-z][a-z0-9_]*/#) != nil: label = .rule(String(name))
        default: return nil
        }
        let paths = position.map { String($0).components(separatedBy: " / ") } ?? []
        let locations = paths.compactMap(Self.location)
        guard locations.count == paths.count, paths.count <= (checkID == "context-optimization" ? 2 : 1) else {
            return nil
        }
        return .finding(label, risk.flatMap { Severity(rawValue: String($0)) }, locations)
    }

    private static func location(_ raw: String) -> Location? {
        guard let match = raw.wholeMatch(of: #/(?:SKILL\.md|Attachment ([1-9][0-9]*))(?::([1-9][0-9]*))?/#) else {
            return nil
        }
        let file: Location.File
        if let attachment = match.1 {
            guard let number = Int(attachment) else { return nil }
            file = .attachment(number)
        } else {
            file = .manifest
        }
        let line = match.2.flatMap { Int($0) }
        if match.2 != nil, line == nil { return nil }
        return Location(file: file, line: line)
    }
}
