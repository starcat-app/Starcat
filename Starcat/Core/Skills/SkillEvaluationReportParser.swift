//
//  SkillEvaluationReportParser.swift
//  Starcat
//
//  把 v1.0.1 的检查证据提取为有界、去敏的 Starcat 报告。
//

import Foundation

/// 只持久化已知标识、状态、分数和定位。终端诊断、上游消息、模型建议与原始附件名均留在临时目录。
enum SkillEvaluationReportParser {
    private struct Report: Decodable {
        let version: String
        let incompleteScans: [String]
        let results: [ResultRow]
    }

    private struct ResultRow: Decodable {
        let publicationEvidence: Evidence
        let status: String
        let passed: Bool
        let skipped: Bool
        let incompleteScans: [String]
        let tier1UnscannedPaths: [String]?
        let findings: [Finding]
        let successDetails: [Success]
        let scanners: [String: String]?
        let quality: Quality?
        let rubricEval: Rubric?
        let llmAnalysis: Analysis?

        func success(_ id: String) -> Success? { successDetails.first { $0.check == id } }
    }

    private struct Evidence: Decodable {
        let schemaVersion: Int
        let producer: String
        let tier: Int
        let checkId: String
    }

    private struct Finding: Decodable {
        let category: String
        let severity: String
        let checkName: String
        let filePath: String?
        let lineNumber: Int?
        let metadata: FindingMetadata?
    }

    private struct FindingMetadata: Decodable {
        let sourceFiles: [String]?
        let score: Double?
        let pathA: String?
        let pathB: String?
    }

    private struct Success: Decodable {
        let check: String
        let metadata: SuccessMetadata?
    }

    private struct SuccessMetadata: Decodable {
        let fileCount: Int?
        let chunkCount: Int?
        let selectedCount: Int?
        let indexedCount: Int?
        let skippedCount: Int?
        let omittedExclusions: Int?
        let entryCount: Int?
        let contentType: String?
    }

    private struct Quality: Decodable {
        let overallScore: Double
        let dimensions: [String: Dimension]

        struct Dimension: Decodable {
            let score: Double
        }
    }

    private struct Rubric: Decodable {
        let executionStatus: String
        let overallScore: Double?
        let overallPass: Bool?
        let checks: [Criterion]?
        let llmProvider: String?
        let llmModelUsed: String?
        let judgeAttempts: Int?

        struct Criterion: Decodable {
            let id: String
            let pass: Bool
            let score: Int
        }
    }

    private struct Analysis: Decodable {
        let provider: String
        let model: String
        let clustersTotal: Int
        let clustersCompleted: Int
        let clustersRefused: Int
        let clustersFailed: Int
        let modelsUsed: [String]?
    }

    private struct HarnessReport: Decodable {
        let harnessCompatibility: [String: [Profile]]

        struct Profile: Decodable {
            let harness: String
            let status: SkillEvaluationHarnessProfile.Status
            let findings: [Rule]
        }

        struct Rule: Decodable {
            let id: String
            let effect: String
        }
    }

    private static let harnessAgents = ["claude-code", "codex", "copilot-cli", "hermes", "openclaw", "opencode"]
    private static let harnessPlacementRules: Set<String> = [
        "CC-ROOT", "CC-GROUPING", "CC-PRECEDENCE", "CX-ROOT", "CX-DEPTH", "CP-ROOT",
        "HM-ROOT", "HM-TRUST", "HM-LINKED-LAYOUT", "OW-ROOT", "OC-ROOT",
    ]

    private static let schemaRules: Set<String> = [
        "author_format", "author_missing", "author_without_email", "body_heading",
        "body_recommended_section", "body_required_section", "duplicate_key", "file_readable",
        "folder_structure", "frontmatter_content", "frontmatter_field", "frontmatter_format",
        "line_count", "manifest_naming", "manifest_required", "metadata_id_duplicate",
        "metadata_id_format", "metadata_id_missing", "name_consistency", "naming_convention",
        "unexpected_file", "yaml_syntax",
    ]
    private static let dimensions = ["correctness", "discoverability", "reliability", "efficiency"]
    private static let rubricWeights = [
        "description_clarity": 3, "instruction_clarity": 3, "example_quality": 3,
        "documentation_completeness": 2, "scope_definition": 2, "professional_tone": 1,
        "trigger_simulation": 3, "workflow_completeness": 3, "error_handling_quality": 2,
    ]

    /// CLI 的 exit 1 同时用于发现和未完成。每个 check 还要独立证明真实覆盖。
    static func parse(
        _ data: Data, mode: SkillEvaluationMode, exitStatus: Int32,
        roots: [URL], files: [[String]], chatModel: String?
    ) throws -> [SkillEvaluationCheck] {
        let expected: [String] = switch mode {
        case .quick: ["schema", "quality"]
        case .security: ["security"]
        case .rubric: ["rubric"]
        case .context: ["context-optimization"]
        case .similarity: ["similarity"]
        }
        let tier = mode == .context || mode == .similarity ? 2 : 1
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard data.count <= SkillEvaluationRunner.maximumReportBytes,
              let report = try? decoder.decode(Report.self, from: data),
              report.version == SkillEvaluationRunner.version,
              (exitStatus == 0 || exitStatus == 1),
              roots.count == files.count, !roots.isEmpty, !report.results.isEmpty,
              report.results.count <= expected.count else { throw SkillEvaluationFailure("invalidReport") }

        var rows: [String: ResultRow] = [:]
        for row in report.results {
            let evidence = row.publicationEvidence
            guard evidence.schemaVersion == 1, evidence.tier == tier,
                  evidence.producer == "skillevaluator.tier\(tier)",
                  expected.contains(evidence.checkId), rows[evidence.checkId] == nil,
                  ["passed", "failed", "incomplete"].contains(row.status),
                  (row.status == "incomplete" || row.passed == (row.status == "passed"))
            else { throw SkillEvaluationFailure("invalidReport") }
            rows[evidence.checkId] = row
        }

        // 顶层可能汇总某个检查的缺口。已归属的缺口不应污染同一报告里完成的其他检查。
        let uncovered = Set(report.incompleteScans)
            .subtracting(report.results.flatMap(\.incompleteScans))
        if exitStatus == 1, report.results.allSatisfy({ $0.status == "passed" && !$0.skipped }),
           uncovered.isEmpty, rows.count == expected.count {
            throw SkillEvaluationFailure("invalidReport")
        }
        return expected.map { id in
            guard let row = rows[id] else { return incomplete(id, ["Check absent from report"]) }
            let position: (Finding) -> String? = { location($0, root: roots[0], files: files[0]) }
            let check: SkillEvaluationCheck = switch id {
            case "schema": schema(row, position: position)
            case "quality": quality(row)
            case "security": security(row, position: position)
            case "rubric": rubric(row, chatModel: chatModel)
            case "context-optimization": context(row, chatModel: chatModel, position: position)
            default: similarity(row, count: roots.count)
            }
            guard uncovered.isEmpty, row.incompleteScans.isEmpty, row.tier1UnscannedPaths?.isEmpty != false,
                  !row.skipped, row.status != "incomplete" else {
                return incomplete(id, ["Check coverage incomplete"] + check.details)
            }
            return check
        }
    }

    private static func schema(_ row: ResultRow, position: (Finding) -> String?) -> SkillEvaluationCheck {
        let id = "schema"
        // 上游以临时绝对路径中的 skills/team-skills 判定安装层级，正负结论都不保留。
        let findings = row.findings.filter {
            $0.category == "SCHEMA" && $0.checkName != "folder_hierarchy" && $0.severity != "info"
        }
        let details = ["Source hierarchy unavailable from snapshot"] + findings.prefix(24).map {
            evidence(schemaRules.contains($0.checkName) ? $0.checkName : "Schema finding", $0, position)
        }
        guard row.success("manifest_exists") != nil,
              row.success("frontmatter_valid") != nil || !findings.isEmpty else { return incomplete(id, details) }
        // 临时层级的高严重度也可能单独导致上游失败。
        if findings.isEmpty, !row.passed,
           !row.findings.contains(where: { $0.category == "SCHEMA" && $0.checkName == "folder_hierarchy" }) {
            return incomplete(id, details)
        }
        return check(id, findings: !findings.isEmpty, details: details)
    }

    private static func quality(_ row: ResultRow) -> SkillEvaluationCheck {
        let id = "quality"
        let scope = ["Static scoring includes English-language heuristics"]
        guard let quality = row.quality, validScore(quality.overallScore),
              row.success("quality_score") != nil,
              dimensions.allSatisfy({ quality.dimensions[$0].map { validScore($0.score) } == true })
        else { return incomplete(id, scope) }
        let details = scope + dimensions.compactMap { dimension in
            quality.dimensions[dimension].map { "\(dimension) \($0.score)/100" }
        }
        return check(id, findings: !row.passed || row.findings.contains { $0.category == "QUALITY" },
                     score: quality.overallScore, details: details)
    }

    /// v1.0.1 仅在独立命令的 JSON 中给出矩阵。绝不采用 listed.text 或上游消息，
    /// 这些字段可包含待评正文。用移除安装路径规则后最严格的结果作为内容结论。
    static func harness(_ data: Data?, root: URL) -> SkillEvaluationCheck {
        let scope = ["Static profiles only; installation location and other agents are outside scope"]
        let missing = ["Agent profile coverage incomplete"]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data, data.count <= SkillEvaluationRunner.maximumReportBytes,
              let report = try? decoder.decode(HarnessReport.self, from: data),
              report.harnessCompatibility.count == 1,
              let profiles = report.harnessCompatibility[root.path] else {
            return incomplete("harness", scope + missing)
        }
        typealias Status = SkillEvaluationHarnessProfile.Status
        func status(_ rules: [HarnessReport.Rule]) -> Status {
            if rules.contains(where: { $0.effect == "not_loaded" }) { return .notLoaded }
            return rules.contains(where: { $0.effect == "degraded" }) ? .degraded : .loads
        }
        let grouped = Dictionary(grouping: profiles, by: \.harness)
        let matrix = harnessAgents.compactMap { agent -> SkillEvaluationHarnessProfile? in
            guard let rows = grouped[agent], rows.count == 1, let profile = rows.first,
                  profile.findings.count <= 32, status(profile.findings) == profile.status,
                  Set(profile.findings.map(\.id)).count == profile.findings.count,
                  profile.findings.allSatisfy({ ["not_loaded", "degraded", "advisory"].contains($0.effect) })
            else { return nil }
            let retained = profile.findings.filter { !harnessPlacementRules.contains($0.id) }
            // 仅接收上游 YAML 使用的短规则编号，拒绝路径、正文和自由格式提示。
            let ids = retained.map(\.id).filter {
                $0.range(of: #"\A[A-Z]{2}-[A-Z0-9-]{2,26}\z"#, options: .regularExpression) != nil
            }
            return SkillEvaluationHarnessProfile(id: agent, status: status(retained), rules: ids.sorted())
        }
        let complete = matrix.count == harnessAgents.count && grouped.count == harnessAgents.count
        let state: SkillEvaluationState = complete
            ? (matrix.contains { $0.status != .loads } ? .findings : .passed)
            : .incomplete
        return SkillEvaluationCheck(id: "harness", state: state, score: nil,
                                    details: complete ? scope : scope + missing, harnessProfiles: matrix)
    }

    private static func security(_ row: ResultRow, position: (Finding) -> String?) -> SkillEvaluationCheck {
        let id = "security"
        let scope = ["SkillSpector static scan"]
        let findings = row.findings.filter { $0.severity != "info" }
        guard row.scanners?["skillspector"] == "2.13.4",
              row.tier1UnscannedPaths == [],
              row.success("skillspector") != nil || !findings.isEmpty else { return incomplete(id, scope) }
        let details = scope + ["SkillSpector 2.13.4", "Findings \(findings.count)"]
            + findings.prefix(24).map { evidence("Security finding", $0, position) }
        return check(id, findings: !row.passed || !findings.isEmpty, details: details)
    }

    private static func rubric(_ row: ResultRow, chatModel: String?) -> SkillEvaluationCheck {
        let id = "rubric"
        guard let result = row.rubricEval, result.executionStatus == "succeeded",
              let score = result.overallScore, validScore(score), let pass = result.overallPass, pass == row.passed,
              let criteria = result.checks, criteria.count == rubricWeights.count,
              Set(criteria.map(\.id)) == Set(rubricWeights.keys),
              criteria.allSatisfy({ (0...10).contains($0.score) && $0.pass == ($0.score >= 7) }),
              result.llmProvider == "openai-compatible", let chatModel, result.llmModelUsed == chatModel,
              let attempts = result.judgeAttempts, (1...2).contains(attempts),
              row.success("rubric_eval") != nil else { return incomplete(id, ["Rubric response incomplete"]) }
        let weightedScore = Double(criteria.reduce(0) { $0 + $1.score * (rubricWeights[$1.id] ?? 0) }) * 10
            / Double(rubricWeights.values.reduce(0, +))
        guard abs(score - weightedScore) <= 0.05001,
              pass == (score >= 70 && criteria.allSatisfy(\.pass)) else { return incomplete(id, []) }
        return check(id, findings: !pass, score: score,
                     details: criteria.map { "\($0.id) \($0.score)/10" })
    }

    private static func context(
        _ row: ResultRow, chatModel: String?, position: (Finding) -> String?
    ) -> SkillEvaluationCheck {
        let id = "context-optimization"
        let duplicates = row.findings.filter { $0.category == "DUPLICATE" && $0.checkName == "duplicate" }
        let details = duplicates.prefix(24).map { evidence("Duplicate content", $0, position) }
        guard let files = row.success("file_collection")?.metadata?.fileCount, files > 0,
              let chunks = row.success("chunking")?.metadata?.chunkCount, chunks >= 2 else {
            return incomplete(id, ["Insufficient text for comparison"] + details)
        }
        let coverage = ["Text files \(files)", "Chunks \(chunks)"]
        guard let analysis = row.llmAnalysis else {
            // 没有相似簇时，上游完成向量比较后直接返回。
            guard row.passed, row.findings.isEmpty, row.success("context_dedup") != nil else {
                return incomplete(id, coverage + details)
            }
            return check(id, findings: false, details: coverage + ["Clusters requiring review 0"])
        }
        let clusterDetails = coverage + ["Reviewed clusters \(analysis.clustersCompleted)/\(analysis.clustersTotal)"] + details
        guard analysis.provider == "openai-compatible", let chatModel, analysis.model == chatModel,
              analysis.modelsUsed == [chatModel], analysis.clustersTotal > 0,
              analysis.clustersCompleted == analysis.clustersTotal,
              analysis.clustersFailed == 0, analysis.clustersRefused == 0,
              duplicates.count <= analysis.clustersCompleted, row.passed || !duplicates.isEmpty
        else { return incomplete(id, clusterDetails) }
        return check(id, findings: !duplicates.isEmpty, details: clusterDetails)
    }

    private static func similarity(_ row: ResultRow, count: Int) -> SkillEvaluationCheck {
        let id = "similarity"
        let coverage = row.success("collection_coverage")?.metadata
        let index = row.success("index_built")?.metadata
        let details = ["Description comparison", "Indexed skills \(coverage?.indexedCount ?? 0)/\(count)"]
        let pairs = row.findings.filter { $0.category == "SIMILARITY" && $0.metadata?.score != nil }
        // Coverage may count extracted manifests before embeddings succeed. Require the finished index and comparison.
        guard coverage?.selectedCount == count, coverage?.indexedCount == count, coverage?.skippedCount == 0,
              coverage?.omittedExclusions == 0, index?.entryCount == count, index?.contentType == "skill",
              pairs.isEmpty ? row.passed && row.success("similarity_check") != nil : true
        else { return incomplete(id, details) }

        var matches: [String] = []
        var seen = Set<String>()
        var highest: Double?
        for pair in pairs {
            guard let score = pair.metadata?.score, (0.75...1).contains(score),
                  let a = itemIndex(pair.metadata?.pathA, count: count),
                  let b = itemIndex(pair.metadata?.pathB, count: count), a != b
            else { return incomplete(id, details) }
            let label = "Items \(min(a, b)) and \(max(a, b))"
            guard seen.insert(label).inserted else { return incomplete(id, details) }
            matches.append("\(label) (\(score))")
            highest = max(highest ?? score, score)
        }
        return check(id, findings: !pairs.isEmpty, score: highest, details: details + Array(matches.prefix(24)))
    }

    private static func itemIndex(_ path: String?, count: Int) -> Int? {
        guard let path, let first = path.split(separator: "/").first, first.hasPrefix("item-"),
              let index = Int(first.dropFirst(5)), (1...count).contains(index),
              path == "item-\(index)" || path == "item-\(index)/SKILL.md" else { return nil }
        return index
    }

    /// 附件路径只用于匹配可信清单。用固定文件名或排序后的附件位置定位，避免持久化带敏感数据的文件名。
    private static func location(_ finding: Finding, root: URL, files: [String]) -> String? {
        func fileLabel(_ path: String) -> String? {
            let relative = path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
            if relative == "SKILL.md", files.contains(relative) { return "SKILL.md" }
            let attachments = files.filter { $0 != "SKILL.md" }
            return attachments.firstIndex(of: relative).map { "Attachment \($0 + 1)" }
        }
        guard let path = finding.filePath, let label = fileLabel(path) else { return nil }
        var detail = label
        if let line = finding.lineNumber, (1...10_000_000).contains(line) { detail += ":\(line)" }
        if finding.category == "DUPLICATE", let sources = finding.metadata?.sourceFiles,
           let other = sources.prefix(16).compactMap(fileLabel).first(where: { $0 != label }) {
            detail += " / " + other
        }
        return detail
    }

    private static func evidence(_ label: String, _ finding: Finding, _ position: (Finding) -> String?) -> String {
        let allowed = ["critical", "high", "medium", "low", "info"]
        let severity = allowed.contains(finding.severity) ? " (\(finding.severity))" : ""
        return label + severity + (position(finding).map { " · " + $0 } ?? "")
    }

    private static func validScore(_ score: Double) -> Bool { (0...100).contains(score) }

    private static func check(
        _ id: String, findings: Bool, score: Double? = nil, details: [String]
    ) -> SkillEvaluationCheck {
        SkillEvaluationCheck(id: id, state: findings ? .findings : .passed, score: score, details: details)
    }

    private static func incomplete(_ id: String, _ details: [String]) -> SkillEvaluationCheck {
        SkillEvaluationCheck(id: id, state: .incomplete, score: nil, details: details)
    }
}
