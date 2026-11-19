//
//  SkillEvaluationRunnerTests.swift
//  StarcatTests
//
//  v1.0.1 报告实测字段的精简快照及离线进程生命周期验证。
//

import Darwin
import Foundation
import Testing
@testable import Starcat

/// 输入仅为合成报告或会议笔记，无模型网络和待评脚本执行。
struct SkillEvaluationRunnerTests {
    private let root = URL(fileURLWithPath: "/private/tmp/evaluation-fixture/agenda-notes")
    private let secret = "synthetic-private-marker"

    @Test func staticReportKeepsActualFindingsAndDiscardsSnapshotHierarchy() throws {
        let schema = row("schema", status: "failed", findings: [
            finding("SCHEMA", "folder_hierarchy", "medium"),
            finding("SCHEMA", "body_heading", "high", line: 8),
        ], success: [success("manifest_exists"), success("frontmatter_valid")])
        let quality = row("quality", success: [success("quality_score")], extra: [
            "quality": ["overall_score": 80.8, "dimensions": [
                "correctness": ["score": 75], "discoverability": ["score": 95],
                "reliability": ["score": 75], "efficiency": ["score": 80],
            ]],
        ])
        let checks = try parse([schema, quality], .quick, status: 1)
        #expect(checks.map(\.state) == [.findings, .passed])
        #expect(checks[0].details.contains { $0.contains("body_heading") && $0.contains("SKILL.md:8") })
        #expect(!checks[0].details.joined().contains("folder_hierarchy"))
        #expect(checks[1].score == 80.8)
        try expectSanitized(checks)
    }

    @Test func harnessRequiresEachProfileAndIgnoresInstallationPositionAndRawText() throws {
        var profiles = harnessRows()
        let codex = try #require(profiles.firstIndex { $0["harness"] as? String == "codex" })
        profiles[codex]["status"] = "not_loaded"
        profiles[codex]["findings"] = [
            ["id": "CX-ROOT", "effect": "not_loaded", "message": secret],
            ["id": "CX-DESC-CUT", "effect": "degraded", "message": secret],
        ]
        let full = try JSONSerialization.data(withJSONObject: ["harness_compatibility": [root.path: profiles]])
        let result = SkillEvaluationReportParser.harness(full, root: root)
        #expect(result.state == .findings)
        #expect(result.harnessProfiles?.count == 6)
        #expect(result.harnessProfiles?[codex].status == .degraded)
        #expect(result.harnessProfiles?[codex].rules == ["CX-DESC-CUT"])
        try expectSanitized([result])

        let partial = try JSONSerialization.data(withJSONObject: [
            "harness_compatibility": [root.path: Array(profiles.dropLast())],
        ])
        #expect(SkillEvaluationReportParser.harness(partial, root: root).state == .incomplete)
        #expect(SkillEvaluationReportParser.harness(full, root: root.deletingLastPathComponent()).state == .incomplete)
    }

    @Test func incompleteSecurityCannotUseVersionAsProof() throws {
        let clean = row("security", success: [success("skillspector")], extra: [
            "scanners": ["skillspector": "2.13.4"],
        ])
        #expect(try parse([clean], .security, status: 0)[0].state == .passed)
        let partial = clean.merging([
            "status": "incomplete",
            "incomplete_scans": ["skillspector"],
            "tier1_unscanned_paths": [root.path + "/" + secret],
        ]) { _, new in new }
        let checks = try parse([partial], .security, status: 1, incomplete: ["skillspector"])
        #expect(checks[0].state == .incomplete)
        try expectSanitized(checks)
        #expect(try parse([row("security")], .security, status: 0)[0].state == .incomplete)
    }

    @Test func rubricRequiresCompleteJudgedCriteriaAndMatchingModel() throws {
        let criteria = [
            "description_clarity", "instruction_clarity", "example_quality", "documentation_completeness",
            "scope_definition", "professional_tone", "trigger_simulation", "workflow_completeness",
            "error_handling_quality",
        ].map { ["id": $0, "score": 9, "pass": true, "notes": secret] as [String: Any] }
        let evidence: [String: Any] = [
            "execution_status": "succeeded", "overall_pass": true, "overall_score": 90,
            "llm_provider": "openai-compatible", "llm_model_used": "local-test-chat",
            "judge_attempts": 1, "checks": criteria, "summary": secret,
        ]
        let valid = row("rubric", success: [success("rubric_eval")], extra: ["rubric_eval": evidence])
        let checks = try parse([valid], .rubric, status: 0)
        #expect(checks[0].state == .passed)
        #expect(checks[0].score == 90)
        #expect(checks[0].details.count == 9)
        try expectSanitized(checks)

        for mutation: [String: Any] in [
            ["checks": Array(criteria.dropLast())],
            ["llm_model_used": "other-model"],
            ["execution_status": "failed"],
        ] {
            let invalid = evidence.merging(mutation) { _, new in new }
            let row = row("rubric", success: [success("rubric_eval")], extra: ["rubric_eval": invalid])
            #expect(try parse([row], .rubric, status: 0)[0].state == .incomplete)
        }
    }

    @Test func contextReportsLocationsAndRequiresEveryCluster() throws {
        let collection = [success("file_collection", ["file_count": 2]), success("chunking", ["chunk_count": 2])]
        let analysis: [String: Any] = [
            "provider": "openai-compatible", "model": "local-test-chat", "models_used": ["local-test-chat"],
            "clusters_total": 1, "clusters_completed": 1, "clusters_refused": 0, "clusters_failed": 0,
        ]
        let context = row("context-optimization", tier: 2, status: "failed", findings: [
            finding("DUPLICATE", "duplicate", "high", line: 8,
                    metadata: ["source_files": ["SKILL.md", "references/\(secret).md"]]),
        ], success: collection, extra: ["llm_analysis": analysis])
        let checks = try parse([context], .context, status: 1)
        #expect(checks[0].state == .findings)
        #expect(checks[0].details.contains { $0.contains("SKILL.md:8 / Attachment 1") })
        try expectSanitized(checks)

        let refused = row("context-optimization", tier: 2, success: collection, extra: [
            "llm_analysis": analysis.merging(["clusters_completed": 0, "clusters_refused": 1]) { _, new in new },
        ])
        #expect(try parse([refused], .context, status: 0)[0].state == .incomplete)
        let noClusters = row("context-optimization", tier: 2, success: collection + [success("context_dedup")])
        #expect(try parse([noClusters], .context, status: 0)[0].state == .passed)
    }

    @Test func similarityRequiresCompletedIndexAndExactSelectedSet() throws {
        let coverage = success("collection_coverage", [
            "selected_count": 2, "indexed_count": 2, "skipped_count": 0, "omitted_exclusions": 0,
        ])
        let index = success("index_built", ["entry_count": 2, "content_type": "skill"])
        let pair = finding("SIMILARITY", "EXACT_DUPLICATE", "critical",
                           metadata: ["score": 1, "path_a": "item-1", "path_b": "item-2", "entry_a": secret])
        let valid = row("similarity", tier: 2, status: "failed", findings: [pair], success: [coverage, index])
        let checks = try parse([valid], .similarity, status: 1)
        #expect(checks[0].state == .findings)
        #expect(checks[0].score == 1)
        #expect(checks[0].details.contains("Items 1 and 2 (1.0)"))
        try expectSanitized(checks)
        let unindexed = row("similarity", tier: 2, status: "failed", success: [coverage])
        #expect(try parse([unindexed], .similarity, status: 1)[0].state == .incomplete)
        let unexpectedPair = finding("SIMILARITY", "EXACT_DUPLICATE", "critical",
                                     metadata: ["score": 1, "path_a": "item-1", "path_b": "item-3"])
        let outside = row("similarity", tier: 2, status: "failed", findings: [unexpectedPair], success: [coverage, index])
        #expect(try parse([outside], .similarity, status: 1)[0].state == .incomplete)
    }

    @Test func mismatchedOrDuplicateReportEvidenceIsRejected() {
        #expect(throws: SkillEvaluationFailure.self) { try parse([row("security")], .quick, status: 0) }
        #expect(throws: SkillEvaluationFailure.self) { try parse([row("schema"), row("schema")], .quick, status: 0) }
        #expect(throws: SkillEvaluationFailure.self) { try parse([row("security")], .security, status: 2) }
    }

    @Test func argumentsAndCredentialsMatchMode() throws {
        let model = SkillEvaluationSelection(providerID: "local", endpoint: "https://example.invalid/v1",
                                             chat: "local-test-chat", embedding: "local-test-embedding")
        #expect(SkillEvaluationRunner.command(for: .quick).arguments == ["tier1", "--checks", "schema,quality", "--no-llm"])
        #expect(SkillEvaluationRunner.command(for: .security).arguments == ["tier1", "--checks", "security", "--no-llm"])
        #expect(SkillEvaluationRunner.command(for: .rubric).arguments == ["rubric-eval"])
        #expect(SkillEvaluationRunner.command(for: .context).arguments == ["context-optimization-check"])
        #expect(SkillEvaluationRunner.command(for: .similarity).arguments == ["similarity-check", "--type", "skill"])
        for mode in SkillEvaluationMode.allCases {
            let env = try SkillEvaluationRunner.modelEnvironment(mode: mode, model: model, apiKey: secret)
            #expect((env["SKILL_EVAL_LLM_API_KEY"] == secret) == mode.needsChat)
            #expect((env["SKILL_EVAL_EMBEDDING_API_KEY"] == secret) == mode.needsEmbedding)
            #expect((env["SKILL_EVAL_LLM_BASE_URL"] == model.endpoint) == mode.needsChat)
            #expect((env["SKILL_EVAL_EMBEDDING_MODEL"] == model.embedding) == mode.needsEmbedding)
            #expect(env["OPENAI_API_KEY"] == nil)
        }
    }

    @Test func versionProbeRejectsMismatchAndBinariesInsideSnapshot() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let workspace = temporary.appendingPathComponent("work")
        let snapshot = workspace.appendingPathComponent("space in name")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("Meeting notes fixture".utf8).write(to: snapshot.appendingPathComponent("SKILL.md"))
        let binary = try SkillEvaluationTestTool.executable("wrong-version")
        let input = SkillEvaluationInput(root: snapshot, version: "fixture", name: "notes")
        await #expect {
            try await SkillEvaluationRunner.run(executable: binary, mode: .quick, inputs: [input],
                                                workspace: workspace, model: nil, apiKey: nil)
        } throws: {
            ($0 as? SkillEvaluationFailure)?.code == "toolVersion"
        }
        let inSnapshot = snapshot.appendingPathComponent("evaluator")
        try FileManager.default.copyItem(at: binary, to: inSnapshot)
        await #expect {
            try await SkillEvaluationRunner.run(executable: inSnapshot, mode: .quick, inputs: [input],
                                                workspace: workspace, model: nil, apiKey: nil)
        } throws: {
            ($0 as? SkillEvaluationFailure)?.code == "input"
        }
    }

    @Test func quickRunnerUsesIsolatedEnvironmentAndJSONReport() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let workspace = temporary.appendingPathComponent("work")
        let snapshot = workspace.appendingPathComponent("space in name")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("Meeting notes fixture".utf8).write(to: snapshot.appendingPathComponent("SKILL.md"))
        let binary = try SkillEvaluationTestTool.executable()
        let result = try await SkillEvaluationRunner.run(
            executable: binary, mode: .quick, inputs: [SkillEvaluationInput(root: snapshot, version: "fixture", name: "notes")],
            workspace: workspace, model: nil, apiKey: secret
        )
        #expect(result.map(\.state) == [.passed, .passed, .passed])
        #expect(result.last?.harnessProfiles?.count == 6)
        #expect(!result.flatMap(\.details).joined().contains("terminal-only-diagnostic"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.path) == ["space in name"])
    }

    @Test(arguments: [true, false])
    func cancellationAndTimeoutDrainChildProcessGroup(cancel: Bool) async throws {
        let path = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: path) }
        let pids = path.appendingPathComponent("pids")
        let task = Task {
            try await SkillEvaluationChild.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/bin/sleep 30 & printf '%s %s\\n' \"$$\" \"$!\" > \"$1\"; wait", "fixture", pids.path],
                environment: ["PATH": "/usr/bin:/bin", "HOME": path.path], cwd: path,
                stdout: nil, watchedFile: pids, byteLimit: 128,
                timeout: cancel ? .seconds(4) : .seconds(1), budgetError: "invalidReport"
            )
        }
        defer { task.cancel() }
        var group: pid_t?
        for _ in 0..<75 {
            if let text = try? String(contentsOf: pids, encoding: .utf8),
               let first = text.split(separator: " ").first, let pid = pid_t(first), text.hasSuffix("\n") {
                group = pid
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(group)
        if cancel {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: SkillEvaluationFailure.self) { try await task.value }
        }
        #expect(Darwin.kill(-pid, 0) == -1)
    }

    // 只保留真实 JSON 中解析器读取的形状，故意把私密标记放进原文和诊断字段。
    private func row(
        _ id: String, tier: Int = 1, status: String = "passed", findings: [[String: Any]] = [],
        success: [[String: Any]] = [], extra: [String: Any] = [:]
    ) -> [String: Any] {
        [
            "publication_evidence": [
                "schema_version": 1, "producer": "skillevaluator.tier\(tier)", "tier": tier, "check_id": id,
            ],
            "status": status, "passed": status == "passed", "skipped": false, "incomplete_scans": [String](),
            "tier1_unscanned_paths": [String](), "findings": findings, "success_details": success,
        ].merging(extra) { _, new in new }
    }

    private func success(_ check: String, _ metadata: [String: Any] = [:]) -> [String: Any] {
        ["check": check, "metadata": metadata]
    }

    private func harnessRows() -> [[String: Any]] {
        ["claude-code", "codex", "copilot-cli", "hermes", "openclaw", "opencode"].map {
            ["harness": $0, "status": "loads", "findings": [[String: String]](), "listed": ["text": secret]]
        }
    }

    private func finding(
        _ category: String, _ rule: String, _ severity: String, line: Int? = nil,
        metadata: [String: Any] = [:]
    ) -> [String: Any] {
        var value: [String: Any] = [
            "category": category, "check_name": rule, "severity": severity, "file_path": root.path + "/SKILL.md",
            "message": secret, "line_content": secret, "suggestion": secret, "metadata": metadata,
        ]
        value["line_number"] = line
        return value
    }

    private func parse(
        _ rows: [[String: Any]], _ mode: SkillEvaluationMode, status: Int32, incomplete: [String] = []
    ) throws -> [SkillEvaluationCheck] {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": "1.0.1", "results": rows, "incomplete_scans": incomplete, "publication_status": "incomplete",
        ])
        let roots = mode == .similarity ? [root, root.deletingLastPathComponent().appendingPathComponent("decision-notes")] : [root]
        return try SkillEvaluationReportParser.parse(
            data, mode: mode, exitStatus: status, roots: roots,
            files: roots.map { _ in ["SKILL.md", "references/\(secret).md"] }, chatModel: "local-test-chat"
        )
    }

    private func expectSanitized(_ checks: [SkillEvaluationCheck]) throws {
        let json = String(decoding: try JSONEncoder().encode(checks), as: UTF8.self)
        #expect(!json.contains(secret))
        #expect(!json.contains("private"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

}
