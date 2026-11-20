//
//  DiagnosticReportTests.swift
//  StarcatTests
//
//  验证报告线索的时间精度、真实故障计数和导出载荷，不打开窗口或调用系统授权。
//

import Foundation
import MCP
import Testing
@testable import Starcat

/// 覆盖“0 条记录”与采集失败的区别，以及 GUI / 公共导出共用的时间语义。
@Suite("Diagnostic report")
struct DiagnosticReportTests {
    @Test("刚刚与自定时间不改变诊断选取范围，未选功能保持空值")
    func timeChoices() {
        let now = Date(timeIntervalSince1970: 1_795_132_800)
        var draft = DiagnosticReportDraft()
        let initial = draft.exportOptions(now: now)
        #expect(initial.occurredAt == now)
        #expect(initial.occurredOn == nil)
        #expect(initial.module.isEmpty)
        #expect(initial.since != nil)
        draft.timeChoice = .custom
        draft.customTime = now.addingTimeInterval(-300)
        draft.module = .search
        let custom = draft.exportOptions(now: now)
        #expect(custom.occurredAt == draft.customTime)
        #expect(custom.module == "search")
        #expect(custom.occurredOn == nil)
    }

    @Test("今天按本机时区保存公历日期，不伪造午夜时分秒")
    func dayPrecision() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-19T20:00:00Z"))
        var draft = DiagnosticReportDraft()
        draft.timeChoice = .today
        let options = draft.exportOptions(now: now, timeZone: try #require(TimeZone(identifier: "Asia/Shanghai")))
        #expect(options.occurredAt == nil)
        #expect(options.occurredOn == "2026-11-20")
        draft.description = String(repeating: "文", count: 2100)
        #expect(draft.exportOptions().description.count == 2000)
    }

    @Test("无记录与存储失败、丢失、超时及坏行分别表达")
    func evidenceGaps() {
        let cutoff = Date().addingTimeInterval(-86400)
        #expect(DiagnosticReportEvidence.read(nil, since: cutoff) == .unavailable)
        #expect(DiagnosticReportEvidence.read(snapshot(""), since: cutoff) == .available(count: 0, incomplete: false))
        for key in ["readFailures", "writeFailures", "rotationFailures", "droppedEvents", "damagedLines", "captureUnavailable"] {
            #expect(DiagnosticReportEvidence.read(snapshot("", health: [key: 1]), since: cutoff)
                == .available(count: 0, incomplete: true))
        }
        #expect(DiagnosticReportEvidence.read(snapshot("invalid-json"), since: cutoff)
            == .available(count: 0, incomplete: true))
    }

    @Test("预览只统计选取范围内的严重故障，不把普通阶段当成故障")
    func evidenceCount() throws {
        let now = Date()
        var failure = DiagnosticEvent(level: .error, visibility: .issue, category: "ai", operation: "chat",
            message: "failure", summaryKey: DiagnosticIssue.aiUnavailable.rawValue,
            outcome: .failed, impact: .blocked)
        failure.timestamp = ISO8601DateFormatter.shared.string(from: now)
        var oldFailure = failure
        oldFailure.timestamp = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(-90000))
        let success = DiagnosticEvent(level: .info, category: "ai", operation: "chat", message: "success", outcome: .succeeded)
        let text = try [failure, oldFailure, success].map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        #expect(DiagnosticReportEvidence.read(snapshot(text), since: now.addingTimeInterval(-86400))
            == .available(count: 1, incomplete: false))
    }

    @Test("空事件诊断包保留日精度线索、环境资料与清单")
    func emptyArchiveWithContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let options = DiagnosticExportOptions(description: "Search did not return results", module: "search", occurredOn: "2026-11-20")
        let input = DiagnosticArchiveBuilder.Input(snapshot: snapshot(""), settings: [:], options: options,
                                                   sessions: nil, localAI: [], collectors: [], system: nil)
        _ = try DiagnosticArchiveBuilder.writePayload(input: input, to: root, exportID: "empty")
        let feedback = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: root.appendingPathComponent("user-feedback.json")))
        #expect(feedback["occurredOn"] == "2026-11-20")
        #expect(feedback["occurredAt"] == nil)
        #expect(try Data(contentsOf: root.appendingPathComponent("events.jsonl")).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("environment.json").path))
    }

    @Test("公共导出接受同一时间精度，并在开始任务前拒绝无效或冲突日期")
    @MainActor
    func publicTimeContext() throws {
        let spec = try #require(StarcatMCPPublicCatalog.specs.first { $0.name == "export_diagnostics" })
        try StarcatMCPInputValidator.validate(.object(["occurred_on": .string("2026-11-20")]), schema: spec.schema)
        let options = try StarcatMCPPublicFacade.diagnosticExportOptions(["occurred_on": .string("2026-11-20")])
        #expect(options.occurredOn == "2026-11-20")
        #expect(try StarcatMCPPublicFacade.diagnosticExportOptions(["occurred_at": .string("2026-11-20T01:00:00Z")]).occurredAt != nil)
        #expect(try StarcatMCPPublicFacade.diagnosticExportOptions(["occurred_at": .string("2026-11-20T01:00:00.123Z")]).occurredAt != nil)
        for arguments: [String: Value] in [
            ["occurred_on": .string("2026-02-30")], ["occurred_on": .string("2026-1-2")],
            ["occurred_at": .string("not-a-date")],
            ["occurred_at": .string("2026-11-20T01:00:00Z"), "occurred_on": .string("2026-11-20")]
        ] {
            #expect(throws: StarcatMCPError.self) { try StarcatMCPPublicFacade.diagnosticExportOptions(arguments) }
        }
    }

    @Test("自绘月历包含闰日，遵循周起始日并保持六行稳定布局")
    func monthCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        let february = try #require(calendar.date(from: DateComponents(year: 2024, month: 2, day: 15)))
        let grid = DiagnosticReportDraft.monthDays(containing: february, calendar: calendar)
        #expect(grid.count == 42)
        #expect(grid.compactMap { $0 }.count == 29)
        #expect(grid.prefix(3).allSatisfy { $0 == nil })
        #expect(calendar.component(.day, from: try #require(grid[3])) == 1)
        #expect(calendar.component(.day, from: try #require(grid.compactMap { $0 }.last)) == 29)
        calendar.firstWeekday = 1
        #expect(DiagnosticReportDraft.monthDays(containing: february, calendar: calendar).prefix(4).allSatisfy { $0 == nil })
    }

    @Test("自绘时分输入保留日期、钳制数值，并禁止未来发生时间")
    func customClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 14, minute: 32)))
        let maximum = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10, minute: 45)))
        let hour = DiagnosticReportDraft.updatingTime(date, hour: 8, calendar: calendar, maximum: maximum)
        #expect(calendar.component(.day, from: hour) == 19)
        #expect(calendar.component(.hour, from: hour) == 8)
        #expect(calendar.component(.minute, from: hour) == 32)
        let bounded = DiagnosticReportDraft.updatingTime(date, hour: 99, minute: -2, calendar: calendar, maximum: maximum)
        #expect(calendar.component(.hour, from: bounded) == 23)
        #expect(calendar.component(.minute, from: bounded) == 0)
        #expect(DiagnosticReportDraft.updatingTime(date, day: maximum, hour: 22, minute: 59,
                                                 calendar: calendar, maximum: maximum) == maximum)
    }

    /// 合成快照只用于读取与归档，不触碰用户的真实诊断目录。
    private func snapshot(_ text: String, health: [String: Int] = [:]) -> DiagnosticSnapshot {
        .init(text: text, cutoffSequence: 0, capturedAt: Date().ISO8601Format(), health: health)
    }
}
