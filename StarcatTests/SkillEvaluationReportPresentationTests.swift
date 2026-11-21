//
//  SkillEvaluationReportPresentationTests.swift
//  StarcatTests
//
//  验证旧报告模板与兼容矩阵的展示转换，无需启动界面或评估进程。
//

import Testing
@testable import Starcat

/// 快照缺口和模板漂移都需要保留证据，避免旧报告被误读为通过。
struct SkillEvaluationReportPresentationTests {
    private typealias Line = SkillEvaluationReportLine

    @Test func matrixRetainsAllSixAgentsAndReportsMissingResults() {
        let rows = SkillEvaluationHarnessRow.rows(for: [
            .init(id: "hermes", status: .notLoaded, rules: ["HM-FORMAT"]),
            .init(id: "claude-code", status: .loads, rules: []),
            .init(id: "codex", status: .degraded, rules: ["CX-DESC-CUT"]),
        ])
        #expect(rows.map(\.id) == ["claude-code", "codex", "copilot-cli", "hermes", "openclaw", "opencode"])
        #expect(rows.map(\.status) == [.reported(.loads), .reported(.degraded), .missing, .reported(.notLoaded), .missing, .missing])
        #expect(rows.map(\.rules) == [[], ["CX-DESC-CUT"], [], ["HM-FORMAT"], [], []])
        #expect(SkillEvaluationHarnessRow.rows(for: nil).map(\.status) == Array(repeating: .missing, count: 6))
    }

    @Test func ambiguousAndUnrecognizedProfilesRetainRuleIDs() throws {
        let rows = SkillEvaluationHarnessRow.rows(for: [
            .init(id: "codex", status: .loads, rules: ["CX-ONE"]),
            .init(id: "codex", status: .degraded, rules: ["CX-TWO"]),
            .init(id: "future-agent", status: .loads, rules: ["FA-ID"]),
        ])
        let codex = try #require(rows.first { $0.id == "codex" })
        #expect(codex.status == .unknown)
        #expect(codex.rules == ["CX-ONE", "CX-TWO"])
        let future = try #require(rows.last)
        #expect(future.id == "future-agent")
        #expect(future.agent == nil && future.status == .unknown && future.rules == ["FA-ID"])
    }

    @Test func generatedTemplatesKeepScoresCountsAndPositions() {
        let manifest = Line.Location(file: .manifest, line: 42)
        let attachment = Line.Location(file: .attachment(3), line: nil)
        let cases: [(String, String, Line)] = [
            ("schema", "Check absent from report", .note(.checkAbsent)),
            ("schema", "body_heading (high) · SKILL.md:42", .finding(.rule("body_heading"), .high, [manifest])),
            ("schema", "Schema finding", .finding(.term(.schemaFinding), nil, [])),
            ("quality", "discoverability 87.125/100", .metric(.discoverability, "87.125/100")),
            ("quality", "efficiency 1e-12/100", .metric(.efficiency, "1e-12/100")),
            ("security", "Findings 99", .metric(.findingCount, "99")),
            ("security", "Security finding (critical)", .finding(.term(.securityFinding), .critical, [])),
            ("security", "Security finding · Attachment 3:42",
             .finding(.term(.securityFinding), nil, [.init(file: .attachment(3), line: 42)])),
            ("rubric", "error_handling_quality 7/10", .metric(.errorHandlingQuality, "7/10")),
            ("context-optimization", "Clusters requiring review 0", .metric(.clustersToReview, "0")),
            ("context-optimization", "Reviewed clusters 1/2", .metric(.reviewedClusters, "1/2")),
            ("context-optimization", "Duplicate content (medium) · SKILL.md:42 / Attachment 3",
             .finding(.term(.duplicateContent), .medium, [manifest, attachment])),
            ("similarity", "Indexed skills 2/3", .metric(.indexedSkills, "2/3")),
            ("similarity", "Items 1 and 3 (0.87654321)", .pair(1, 3, score: "0.87654321")),
        ]
        for (checkID, raw, expected) in cases {
            #expect(Line(checkID: checkID, raw: raw) == expected, "\(raw)")
        }
    }

    @Test func unfamiliarFormatsRemainVerbatim() {
        let cases = [
            ("security", "SkillSpector 2.13.4"),
            ("security", "Security finding (unexpected) · SKILL.md:42"),
            ("security", "Security finding (high) · new-file.md:42"),
            ("security", "Findings 1/2"),
            ("quality", "description_clarity 7/10"),
            ("rubric", "new_criterion 7/10"),
        ]
        for (checkID, raw) in cases {
            #expect(Line(checkID: checkID, raw: raw) == .original(raw), "\(raw)")
        }
    }
}
