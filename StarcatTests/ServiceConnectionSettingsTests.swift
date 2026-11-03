//
//  ServiceConnectionSettingsTests.swift
//  StarcatTests
//
//  自建服务设置的提交边界：自动检测只读，手动测试通过后提交同一份 URL/Key 草稿。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Service connection settings")
struct ServiceConnectionSettingsTests {
    @Test("自动检测不保存，手动测试成功才保存", arguments: [false, true])
    func successfulProbeOnlySavesWhenRequested(manual: Bool) async {
        let model = ServiceConnectionSettingsModel(service: .trending)
        model.draftURL = "https://example.com"
        model.draftAPIKey = " candidate "
        var saved: [(URL?, String?)] = []
        await model.testConnection(savesOnSuccess: manual) { service, url, key in
            #expect(service == .trending)
            #expect(url.host == "example.com")
            #expect(key == "candidate")
            #expect(saved.isEmpty)
            return .ok(statusCode: 200, version: "test")
        } save: { saved.append(($0, $1)) }
        #expect(saved.count == (manual ? 1 : 0))
        if let entry = saved.first {
            #expect(entry.0?.host == "example.com")
            #expect(entry.1 == "candidate")
        }
        #expect(model.test.result?.isHealthy == true)
    }

    @Test("所有不健康响应均不保存", arguments: [0, 1, 2, 3])
    func unhealthyProbeNeverSaves(kind: Int) async {
        let outcome: HealthCheckOutcome = [
            .serviceMismatch, .unauthorized(statusCode: 401),
            .serverError(statusCode: 500), .networkError(reason: "offline")
        ][kind]
        let model = ServiceConnectionSettingsModel(service: .trending)
        model.draftURL = "https://example.com"
        model.draftAPIKey = "new-key"
        await model.testConnection(savesOnSuccess: true) { _, _, _ in outcome } save: { _, _ in
            Issue.record("An unhealthy service must not replace persisted configuration")
        }
        #expect(model.test.result == outcome)
        #expect(model.draftAPIKey == "new-key")
    }

    @Test("修改 URL 或 Key 后旧成功不能保存", arguments: [false, true])
    func editingInvalidatesSnapshot(editsKey: Bool) async throws {
        let model = ServiceConnectionSettingsModel(service: .trending)
        model.draftURL = "https://old.example.com"
        model.draftAPIKey = "old-key"
        var continuation: CheckedContinuation<HealthCheckOutcome, Never>?
        let task = Task {
            await model.testConnection(savesOnSuccess: true) { _, _, _ in
                await withCheckedContinuation { continuation = $0 }
            } save: { _, _ in Issue.record("A stale snapshot must not be saved") }
        }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        if editsKey { model.draftAPIKey = "new-key" }
        else { model.draftURL = "https://new.example.com" }
        #expect(!model.test.isTesting)
        pending.resume(returning: .ok(statusCode: 200, version: nil))
        await task.value
        #expect(model.test.result == nil)
        #expect(model.test.errorMessage == nil)
    }

    @Test("重置使进行中的旧探测失效，不伪造健康结果")
    func resetInvalidatesPendingProbe() async throws {
        let model = ServiceConnectionSettingsModel(service: .trending)
        model.draftURL = "https://old.example.com"
        model.draftAPIKey = "old-key"
        var continuation: CheckedContinuation<HealthCheckOutcome, Never>?
        let task = Task {
            await model.testConnection(savesOnSuccess: true) { _, _, _ in
                await withCheckedContinuation { continuation = $0 }
            } save: { _, _ in Issue.record("A pre-reset probe must not save") }
        }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        let succeeded = await model.reset { url, key in
            #expect(url == nil)
            #expect(key == nil)
        }
        #expect(succeeded)
        #expect(model.draftURL.isEmpty)
        #expect(model.draftAPIKey.isEmpty)
        #expect(model.test.result == nil)
        pending.resume(returning: .ok(statusCode: 200, version: nil))
        await task.value
        #expect(model.test.result == nil)
    }

    @Test("非法地址不发请求，空草稿显式恢复内置连接")
    func invalidAndDefaultDrafts() async {
        let model = ServiceConnectionSettingsModel(service: .trending)
        model.draftURL = "bad-url"
        await model.testConnection(savesOnSuccess: true) { _, _, _ in
            Issue.record("Invalid URLs must not be requested")
            return .ok(statusCode: 200, version: nil)
        } save: { _, _ in Issue.record("Invalid URLs must not be saved") }
        model.draftURL = ""
        await model.testConnection(savesOnSuccess: true) { service, url, key in
            #expect(url == service.productionURL)
            #expect(key == StarcatAPIKeyDefaults.productionKeyOrNil(for: service))
            return .ok(statusCode: 200, version: nil)
        } save: { url, key in
            #expect(url == nil)
            #expect(key == nil)
        }
    }
}
