//
//  StarcatMCPPublicCapabilityTests.swift
//  StarcatTests
//
//  验证公开契约的边界、默认预览和真实任务生命周期；使用可控闭包与时钟，
//  不读取用户数据库、不调用付费 AI、不触发系统授权。
//

import Foundation
import MCP
import Testing
@testable import Starcat

@MainActor
@Suite("Starcat public capabilities")
struct StarcatMCPPublicCapabilityTests {
    @Test("目录名称唯一，写入与生成默认预览，Schema 禁止未知参数")
    func catalogContract() throws {
        let specs = StarcatMCPPublicCatalog.specs
        #expect(Set(specs.map(\.name)).count == specs.count)
        #expect(specs.count >= 30)
        for spec in specs {
            #expect(["read", "write"].contains(spec.permission))
            #expect(spec.schema.objectValue?["additionalProperties"]?.boolValue == false)
            if spec.permission != "read" {
                #expect(spec.properties["dry_run"]?.objectValue?["default"]?.boolValue == true)
            }
            #expect(spec.tool.name == "starcat.\(spec.name)")
        }
    }

    @Test("默认读、默认关闭写；唯一开关覆盖全部写种类并即时生效")
    func twoPermissionBoundary() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test.public.access.\(UUID())")!)
        #expect(settings.mcpAllowWrites == false)
        #expect(throws: StarcatPublicCapabilityError.self) { try StarcatMCPAccess.requireWrite(settings) }
        settings.mcpAllowWrites = true
        try StarcatMCPAccess.requireWrite(settings)
        settings.mcpAllowWrites = false
        #expect(throws: StarcatPublicCapabilityError.self) { try StarcatMCPAccess.requireWrite(settings) }
    }

    @Test("仓库 Skill 文件导出使用写权限和默认预览，不接受客户端路径")
    func skillFileExportContract() throws {
        let spec = try #require(StarcatMCPPublicCatalog.specs.first { $0.name == "export_repo_skill_file" })
        #expect(spec.permission == "write")
        #expect(spec.task)
        let input: Value = .object([
            "repo_id": .int(1), "skill_id": .string("1:commit:skills/review/"), "path": .string("SKILL.md")
        ])
        try StarcatMCPInputValidator.validate(input, schema: spec.schema)
        #expect(throws: StarcatMCPError.self) {
            try StarcatMCPInputValidator.validate(.object([
                "repo_id": .int(1), "skill_id": .string("id"), "path": .string("SKILL.md"),
                "destination": .string("/tmp/client")
            ]), schema: spec.schema)
        }
    }

    @Test("旧本地写设置只迁移一次，不保留细分权限；旧 Star 单独授权不扩大权限")
    func oldPermissionsMigrateOnce() throws {
        for (oldLocal, oldStar, expected) in [(true, false, true), (false, true, false)] {
            let defaults = UserDefaults(suiteName: "test.public.migration.\(UUID())")!
            defaults.set(oldLocal, forKey: "settings.mcp.allowLocalWrites.v1")
            defaults.set(oldStar, forKey: "settings.mcp.allowGitHubStarWrites.v1")
            defaults.set(false, forKey: "settings.mcp.exposePrivateNotes.v1")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.mcpAllowWrites == expected)
            #expect(defaults.object(forKey: "settings.mcp.allowLocalWrites.v1") == nil)
            #expect(defaults.object(forKey: "settings.mcp.exposePrivateNotes.v1") == nil)
            settings.mcpAllowWrites = !expected
            #expect(AppSettings(defaults: defaults).mcpAllowWrites == !expected)
        }
    }

    @Test("服务端拒绝错误类型、未知参数、越界和缺少必填，不依赖 CLI 校验")
    func schemaBoundary() throws {
        let schema = try #require(StarcatMCPPublicCatalog.specs.first { $0.name == "knowledge_search" }).schema
        let valid: Value = .object(["query": .string("SQLite"), "repo_ids": .array([.int(1)])])
        try StarcatMCPInputValidator.validate(valid, schema: schema)
        for invalid: Value in [
            .object(["query": .bool(true), "repo_ids": .array([.int(1)])]),
            .object(["query": .string("SQLite"), "repo_ids": .array([.int(0)])]),
            .object(["query": .string("SQLite"), "repo_ids": .array([])]),
            .object(["query": .string("SQLite")]),
            .object(["query": .string("SQLite"), "repo_ids": .array([.int(1)]), "raw_sql": .string("no")])
        ] {
            #expect(throws: StarcatMCPError.self) {
                try StarcatMCPInputValidator.validate(invalid, schema: schema)
            }
        }
    }

    @Test("任务由 App 保留结果，完成前不能读取，过期后明确失效")
    func taskResultsAndExpiry() async throws {
        var clock = Date()
        let store = StarcatMCPTaskStore(now: { clock })
        let handle = try store.start(kind: "fixture") { .object(["answer": .int(42)]) }
        let id = try #require(handle.objectValue?["task_id"]?.stringValue)
        #expect(throws: StarcatPublicCapabilityError.self) {
            try store.result(id: id)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(try store.status(id: id).objectValue?["state"]?.stringValue == "succeeded")
        #expect(try store.result(id: id).objectValue?["result"]?.objectValue?["answer"]?.intValue == 42)
        clock = clock.addingTimeInterval(3601)
        #expect(throws: StarcatPublicCapabilityError.self) { try store.status(id: id) }
    }

    @Test("文本翻译输入唯一且缓存与仓库隔离，不启动 WebView 或系统翻译")
    func translationRequestContract() throws {
        let input: [String: Value] = [
            "target_language": .string("zh-Hans"),
            "segments": .array([.object(["id": .string("first"), "text": .string("A useful project.")])])
        ]
        let request = try StarcatMCPPublicFacade.translationRequest(input)
        #expect(request.cacheOwner == "starcat-cli")
        #expect(request.cacheRepo.count == 64)
        #expect(request.repoId == nil)
        #expect(request.engine == .ai)
        #expect(request.sourceSegments.first?.text == "A useful project.")
        for _ in 0..<20 {
            #expect(try StarcatMCPPublicFacade.translationRequest(input).cacheRepo == request.cacheRepo)
        }
        var changed = input
        changed["segments"] = .array([.object(["id": .string("first"), "text": .string("Changed source.")])])
        #expect(try StarcatMCPPublicFacade.translationRequest(changed).cacheRepo != request.cacheRepo)
        var duplicate = input
        duplicate["segments"] = .array([
            .object(["id": .string("same"), "text": .string("First")]),
            .object(["id": .string("same"), "text": .string("Second")])
        ])
        #expect(throws: StarcatMCPError.self) { try StarcatMCPPublicFacade.translationRequest(duplicate) }
        var automatic = input
        automatic["target_language"] = .string("auto")
        #expect(throws: StarcatMCPError.self) { try StarcatMCPPublicFacade.translationRequest(automatic) }
    }

    @Test("支持取消的任务先进入 cancelling，切号等待退出后清除结果")
    func cancelAndAccountBarrier() async throws {
        let store = StarcatMCPTaskStore()
        let handle = try store.start(kind: "fixture") {
            try await Task.sleep(for: .seconds(600))
            return .null
        }
        let id = try #require(handle.objectValue?["task_id"]?.stringValue)
        #expect(try store.cancel(id: id).objectValue?["state"]?.stringValue == "cancelling")
        await store.cancelAllAndWait()
        #expect(throws: StarcatPublicCapabilityError.self) { try store.status(id: id) }
        let next = try store.start(kind: "new_account") { .null }
        #expect(next.objectValue?["task_id"]?.stringValue != id)
        await store.cancelAllAndWait()
    }

    @Test("不可取消任务明确拒绝，笔记结果按默认读权限返回，错误不伪装成功")
    func unsupportedCancellationAndPrivacy() async throws {
        let store = StarcatMCPTaskStore()
        let handle = try store.start(kind: "fixture", supportsCancellation: false) { .string("private fixture") }
        let id = try #require(handle.objectValue?["task_id"]?.stringValue)
        #expect(throws: StarcatPublicCapabilityError.self) { try store.cancel(id: id) }
        for _ in 0..<10 { await Task.yield() }
        #expect(try store.result(id: id).objectValue?["result"]?.stringValue == "private fixture")
        let failed = try store.start(kind: "failed") {
            throw StarcatPublicCapabilityError(code: "FIXTURE_FAILURE", message: "fixture")
        }
        let failedID = try #require(failed.objectValue?["task_id"]?.stringValue)
        for _ in 0..<10 { await Task.yield() }
        #expect(try store.status(id: failedID).objectValue?["state"]?.stringValue == "failed")
        #expect(try store.status(id: failedID).objectValue?["error_code"]?.stringValue == "FIXTURE_FAILURE")
    }

    @Test("切号等待已接受的普通请求退出，并拒绝切换期间的新请求与任务")
    func inFlightRequestAccountBarrier() async throws {
        let store = StarcatMCPTaskStore()
        try store.beginRequest()
        var finished = false
        let change = Task { @MainActor in
            await store.cancelAllAndWait()
            finished = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!finished)
        #expect(throws: StarcatPublicCapabilityError.self) { try store.beginRequest() }
        #expect(throws: StarcatPublicCapabilityError.self) { try store.start(kind: "late") { .null } }
        store.endRequest()
        await change.value
        #expect(finished)
        try store.beginRequest()
        store.endRequest()
    }
}
