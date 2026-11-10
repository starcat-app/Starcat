//
//  DiagnosticArchiveTests.swift
//  StarcatTests
//
//  从输入快照验证报告、哈希清单、缺口、隐私和超时契约。
//

import Foundation
import CryptoKit
import Testing
@testable import Starcat

@Suite("Diagnostic archive")
struct DiagnosticArchiveTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-archive-\(UUID())")
    }

    @Test("图谱87/78与授权502生成可验证且安全的报告")
    func reportContract() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = DiagnosticEvent(level: .info, category: "followGraph", operation: "presentation",
            message: "customer private prompt", context: ["token": "sensitive"],
            phase: "renderConfirmed", fields: ["totalCount": .integer(87),
                                             "renderedCount": .integer(78), "canLoadMore": .boolean(false)])
        let failure = DiagnosticEvent(level: .warning, category: "license", operation: "validate",
            message: "request failed", statusCode: 502, errorCode: "provider_error",
            operationID: "sample-operation", serverTraceID: "00000000-0000-0000-0000-000000000001",
            phase: "business", outcome: .failed)
        let encoder = JSONEncoder()
        let text = try [graph, failure].map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }.joined(separator: "\n") + "\ninvalid"
        let input = DiagnosticArchiveBuilder.Input(
            snapshot: DiagnosticSnapshot(text: text, cutoffSequence: 2,
                capturedAt: Date().ISO8601Format(), health: ["droppedEvents": 3]),
            settings: ["hasSettings": "false"], options: .init(since: nil),
            sessions: nil, localAI: [], collectors: [.init(name: "system", status: .notCollected, detail: nil)],
            system: nil)
        let manifest = try DiagnosticArchiveBuilder.writePayload(input: input, to: root, exportID: "example")
        #expect(manifest.damagedLines == 1)
        #expect(manifest.health["droppedEvents"] == 3)
        for file in manifest.files {
            let data = try Data(contentsOf: root.appendingPathComponent(file.path))
            #expect(file.bytes == data.count)
            #expect(file.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("customer private prompt"))
            #expect(!text.contains("sensitive"))
        }
        let report = try String(contentsOf: root.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(report.contains("87"))
        #expect(report.contains("78"))
        #expect(report.contains("502"))
        #expect(report.contains("provider_error"))
        #expect(manifest.collectors.contains { $0.name == "readme" && $0.status == .notCollected })
    }

    @Test("旧格式不补造会话，根操作筛选包含关联子操作")
    func historicalAndRelatedScope() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = [
            DiagnosticEvent(level: .info, category: "license", operation: "root", message: "safe", operationID: "root"),
            DiagnosticEvent(level: .warning, category: "network", operation: "child", message: "safe",
                            operationID: "child", parentOperationID: "root", outcome: .failed),
            DiagnosticEvent(level: .info, category: "network", operation: "unrelated", message: "safe", operationID: "other")
        ]
        let text = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        let input = DiagnosticArchiveBuilder.Input(snapshot: .init(text: text, cutoffSequence: 3,
            capturedAt: Date().ISO8601Format(), health: [:]), settings: [:],
            options: .init(operationID: "root", since: nil), sessions: nil, localAI: [], collectors: [], system: nil)
        _ = try DiagnosticArchiveBuilder.writePayload(input: input, to: root, exportID: "related")
        let exported = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
        #expect(exported.contains("child"))
        #expect(!exported.contains("unrelated"))
        let legacy = try JSONDecoder().decode(DiagnosticEvent.self, from: Data(
            #"{"timestamp":"2026-11-10T00:00:00Z","category":"test","operation":"legacy","level":"info","message":"old"}"#.utf8))
        #expect(legacy.sessionID == nil)
        #expect(legacy.environmentID == nil)
    }

    @Test("采集器超时不等待迟到结果，也不重复恢复 continuation")
    func timeout() async {
        let start = ContinuousClock.now
        let value = await DiagnosticDeadline.capture(seconds: 0.01) {
            try? await Task.sleep(for: .milliseconds(100))
            return "late"
        }
        #expect(value == nil)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("系统附件保留异常数字与栈身份，丢弃路径和未知正文")
    func systemPrivacy() {
        var remaining = 100
        let safe = DiagnosticSystemDiagnostics.sanitize([
            "crashDiagnostics": [["exceptionType": 6, "privatePrompt": "customer prompt",
                                   "callStackTree": ["address": 123, "binaryUUID": UUID().uuidString,
                                                     "sourcePath": "/Users/customer/secret.txt"]]]
        ], depth: 0, remaining: &remaining)
        let data = try? JSONSerialization.data(withJSONObject: safe ?? [:])
        let text = String(decoding: data ?? Data(), as: UTF8.self)
        #expect(text.contains("exceptionType"))
        #expect(text.contains("address"))
        #expect(!text.contains("customer"))
    }

    @Test("系统附件收到后跨实例可用，损坏文件明确报告失败")
    func systemPersistenceAndFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let system = DiagnosticSystemDiagnostics(directory: root)
        system.record(Data(#"{"crashDiagnostics":[{"exceptionType":6,"signal":11,"privateText":"customer-private"}]}"#.utf8),
                      kind: "diagnostic")
        let first = await system.snapshot()
        #expect(first.1.status == .collected)
        #expect(!String(decoding: try #require(first.0), as: UTF8.self).contains("customer-private"))
        let restored = await DiagnosticSystemDiagnostics(directory: root).snapshot()
        #expect(restored.1.status == .collected)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("system-summary.json"))
        let failed = await DiagnosticSystemDiagnostics(directory: root).snapshot()
        #expect(failed.1.status == .failed)
    }

    @Test("安全解码路径保留到导出包，未知值不会补成零")
    func decodingEvidence() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let error = DecodingError.dataCorrupted(.init(codingPath: [],
            debugDescription: "customer-private-response"))
        let event = DiagnosticEvent(level: .error, category: "network", operation: "decode",
            message: "Decode failed", underlying: DiagnosticEvent.summarize(error),
            fields: ["count": .integer(0)], errorChain: DiagnosticFailure.causes(error))
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        let input = DiagnosticArchiveBuilder.Input(snapshot: .init(text: text, cutoffSequence: 1,
            capturedAt: Date().ISO8601Format(), health: [:]), settings: [:], options: .init(since: nil),
            sessions: nil, localAI: [], collectors: [], system: nil)
        _ = try DiagnosticArchiveBuilder.writePayload(input: input, to: root, exportID: "decode")
        let exported = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: Data(exported.utf8))
        #expect(decoded.underlying?.contains("path=<root>") == true)
        #expect(decoded.fields["count"] == .integer(0))
        #expect(decoded.fields["unavailableCount"] == nil)
        #expect(!exported.contains("customer-private-response"))
        #expect(decoded.errorChain.count == 1)
    }

    @Test("导出事件窗口超限保留最近事件并明确报告截断")
    func boundedExportWindow() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = (0..<3).map { n in
            DiagnosticEvent(timestamp: Date().addingTimeInterval(Double(n)), level: .info,
                category: "test", operation: "window", message: "safe", fields: ["count": .integer(n)])
        }
        let text = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        let input = DiagnosticArchiveBuilder.Input(snapshot: .init(text: text, cutoffSequence: 3,
            capturedAt: Date().ISO8601Format(), health: [:]), settings: [:], options: .init(since: nil),
            sessions: nil, localAI: [], collectors: [], system: nil)
        let manifest = try DiagnosticArchiveBuilder.writePayload(input: input, to: root, exportID: "bounded", eventCountLimit: 1)
        let exported = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
        let last = try JSONDecoder().decode(DiagnosticEvent.self, from: Data(exported.utf8))
        #expect(last.fields["count"] == .integer(2))
        #expect(manifest.collectors.contains { $0.name == "eventWindow" && $0.status == .truncated })
        let empty = try DiagnosticArchiveBuilder.writePayload(input: input, to: root, exportID: "bytes", eventByteLimit: 1)
        #expect(empty.actualFirstEvent == nil)
        #expect(empty.collectors.contains { $0.name == "eventWindow" && $0.status == .truncated })
    }

    @Test("临时生成及压缩降级不写未授权的相邻目录，不删除已有目标")
    func compressionFallback() throws {
        let parent = directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("existing.zip")
        try Data("keep previous bundle".utf8).write(to: destination)
        let input = DiagnosticArchiveBuilder.Input(snapshot: .init(text: "", cutoffSequence: 0,
            capturedAt: Date().ISO8601Format(), health: [:]), settings: [:], options: .init(),
            sessions: nil, localAI: [], collectors: [], system: nil)
        let fallback = try DiagnosticBundleExporter.archive(input: input, destination: destination) { root, staged in
            // 原生保存面板只授予目标文件；测试不能因父目录恰好可写而掩盖沙盒回归。
            let destinationParent = parent.standardizedFileURL.path + "/"
            #expect(!root.standardizedFileURL.path.hasPrefix(destinationParent))
            #expect(!staged.standardizedFileURL.path.hasPrefix(destinationParent))
            #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["existing.zip"])
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: fallback) }
        #expect(fallback != destination)
        #expect(fallback.deletingLastPathComponent().standardizedFileURL ==
                FileManager.default.temporaryDirectory.standardizedFileURL)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep previous bundle")
        let manifest = try JSONDecoder().decode(DiagnosticManifest.self,
            from: Data(contentsOf: fallback.appendingPathComponent("manifest.json")))
        #expect(manifest.collectors.contains { $0.name == "compression" && $0.status == .failed })
        #expect(FileManager.default.fileExists(atPath: fallback.appendingPathComponent("report.md").path))
    }

    @Test("实际 ZIP 导出替换成功且不会确认问题提醒")
    @MainActor
    func realExportDoesNotAcknowledge() async throws {
        let parent = directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = DiagnosticLogStore(directoryURL: parent.appendingPathComponent("diagnostics"))
        await store.record(DiagnosticEvent(level: .error, visibility: .issue, category: "database",
                                           operation: "sample", message: "Database operation failed"))
        let target = parent.appendingPathComponent("bundle.zip")
        try Data("old".utf8).write(to: target)
        let result = try await DiagnosticBundleExporter.export(to: target, store: store,
            localAIStore: LocalAILogStore(directoryURL: parent.appendingPathComponent("local-ai"), persistenceEnabled: false),
            systemStore: DiagnosticSystemDiagnostics(directory: parent.appendingPathComponent("system")))
        #expect(result == target)
        #expect(try Data(contentsOf: target).starts(with: [0x50, 0x4b]))
        #expect(await store.issueSummary().issueCount == 1)
    }

    @Test("完整 Swift 导出器生成可供解析 Skill 验证的合成 ZIP")
    func syntheticRoundTripArtifact() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var events: [DiagnosticEvent] = []
        let beginning = Date().addingTimeInterval(-60)
        func append(category: String, phase: String, outcome: DiagnosticEvent.Outcome? = nil,
                    request: String? = nil, status: Int? = nil, fields: [String: DiagnosticValue] = [:]) {
            events.append(DiagnosticEvent(timestamp: beginning.addingTimeInterval(Double(events.count)),
                level: outcome == .failed ? .warning : .info, category: category, operation: "synthetic",
                message: "Synthetic validation evidence", statusCode: status,
                errorCode: status == 502 ? "provider_error" : nil, operationID: category + "-fixture",
                requestID: request, phase: phase, outcome: outcome, fields: fields))
        }
        append(category: "followGraph", phase: "started")
        append(category: "followGraph", phase: "pageMerged",
               fields: ["totalCount": .integer(87), "cachedCount": .integer(87), "hasNextPage": .boolean(false)])
        append(category: "followGraph", phase: "renderConfirmed",
               fields: ["totalCount": .integer(87), "displayedCount": .integer(78), "renderedCount": .integer(78),
                        "budget": .integer(78), "canLoadMore": .boolean(true)])
        append(category: "followGraph", phase: "finished", outcome: .partial)
        for n in 1...5 {
            append(category: "license", phase: "http", outcome: .failed, request: "fixture-\(n)", status: 502)
        }
        append(category: "license", phase: "finished", outcome: .succeeded)
        append(category: "database", phase: "finished", outcome: .cancelled)
        append(category: "runtime", phase: "versionProbe")
        let text = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        let input = DiagnosticArchiveBuilder.Input(snapshot: .init(text: text, cutoffSequence: 12,
            capturedAt: Date().ISO8601Format(), health: ["droppedEvents": 0]), settings: [:],
            options: .init(description: "Synthetic fixture; no customer data", since: nil), sessions: nil,
            localAI: [], collectors: [.init(name: "system", status: .notCollected, detail: "Synthetic fixture")], system: nil)
        let target = root.appendingPathComponent("fixture.zip")
        _ = try DiagnosticBundleExporter.archive(input: input, destination: target)
        #expect(try Data(contentsOf: target).starts(with: [0x50, 0x4b]))
        // App Store 测试容器受系统保护；通过 Test Runner 附件交付合成产物，
        // 而不是让外部脚本绕过容器权限。附件可由 xcresulttool 正常导出。
        Attachment.record(Array(try Data(contentsOf: target)), named: "starcat-diagnostics-validation.zip")
    }
}
