//
//  CompanionPairingTests.swift
//  StarcatTests
//
//  用内存凭据与可控时钟验证配对生命周期、来源隔离、持久化和即时撤销；
//  不启动监听、不读取真实 Keychain、不触发浏览器或 GUI。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Companion pairing")
@MainActor
struct CompanionPairingTests {
    private let origin = "chrome-extension://fixture"

    private func input() -> CompanionPairingStart {
        .init(instanceID: UUID().uuidString, browser: "chrome", name: "Test browser")
    }

    @Test("批准后仅能领取一次独立 token，重启存储后仍可逐设备撤销")
    func approvalClaimPersistenceAndRevocation() throws {
        let keychain = InMemoryKeychain()
        let store = CompanionDeviceStore(keychain: keychain, loadStoredCredentials: true)
        let receipt = try store.start(input(), origin: origin)
        #expect(receipt.code.count == 6)
        #expect(receipt.code.allSatisfy { $0.isNumber })
        #expect(receipt.claimSecret.count >= 40)
        let claim = CompanionPairingClaim(requestID: receipt.requestID, claimSecret: receipt.claimSecret)
        #expect(try store.poll(claim, origin: origin).status == "pending")
        store.approve(requestID: receipt.requestID)
        let result = try store.poll(claim, origin: origin)
        let token = try #require(result.token)
        let deviceID = try #require(result.deviceID)
        #expect(result.scope == "companion")
        #expect(store.authorizedDevice(token: token)?.id == deviceID)
        #expect(try store.poll(claim, origin: origin).token == nil)
        let restored = CompanionDeviceStore(keychain: keychain, loadStoredCredentials: true)
        #expect(restored.authorizedDevice(token: token)?.id == deviceID)
        var disconnected: String?
        restored.onRevoke = { disconnected = $0 }
        try restored.rename(deviceID: deviceID, name: "Work profile")
        #expect(restored.devices.first?.name == "Work profile")
        try restored.revoke(deviceID: deviceID)
        #expect(restored.authorizedDevice(token: token) == nil)
        #expect(disconnected == deviceID)
        #expect(CompanionDeviceStore(keychain: keychain, loadStoredCredentials: true).devices.isEmpty)
    }

    @Test("六位码和请求 ID 不能领取，来源不同也拒绝")
    func claimsAreBoundToOriginAndHighEntropySecret() throws {
        let store = CompanionDeviceStore(keychain: InMemoryKeychain())
        let receipt = try store.start(input(), origin: origin)
        store.approve(requestID: receipt.requestID)
        #expect(throws: CompanionPairingError.self) {
            try store.poll(.init(requestID: receipt.requestID, claimSecret: receipt.code), origin: origin)
        }
        #expect(throws: CompanionPairingError.self) {
            try store.poll(
                .init(requestID: receipt.requestID, claimSecret: receipt.claimSecret),
                origin: "chrome-extension://other"
            )
        }
    }

    @Test("过期、拒绝与取消均为终态，未领取凭据随取消撤销")
    func terminalStatesAndExpiry() throws {
        var clock = Date()
        let store = CompanionDeviceStore(keychain: InMemoryKeychain(), now: { clock })
        let expired = try store.start(input(), origin: origin)
        store.approve(requestID: expired.requestID)
        clock = clock.addingTimeInterval(121)
        #expect(try store.poll(.init(requestID: expired.requestID, claimSecret: expired.claimSecret), origin: origin).status == "expired")
        #expect(store.devices.isEmpty)
        let rejected = try store.start(input(), origin: origin)
        store.reject(requestID: rejected.requestID)
        store.approve(requestID: rejected.requestID)
        #expect(try store.poll(.init(requestID: rejected.requestID, claimSecret: rejected.claimSecret), origin: origin).status == "rejected")
        let cancelled = try store.start(input(), origin: origin)
        store.approve(requestID: cancelled.requestID)
        let claim = CompanionPairingClaim(requestID: cancelled.requestID, claimSecret: cancelled.claimSecret)
        try store.cancel(claim, origin: origin)
        #expect(try store.poll(claim, origin: origin).status == "cancelled")
        #expect(store.devices.isEmpty)
    }

    @Test("凭据写入失败不能批准，重复待核对请求与限频不覆盖已有请求")
    func failedPersistenceAndRequestLimits() throws {
        let failing = CompanionDeviceStore(keychain: InMemoryKeychain(rejectsServiceKeyWrites: true))
        let pending = try failing.start(input(), origin: origin)
        failing.approve(requestID: pending.requestID)
        #expect(failing.approvalFailed)
        #expect(failing.pendingApproval?.id == pending.requestID)
        #expect(failing.devices.isEmpty)
        #expect(throws: CompanionPairingError.self) { try failing.start(input(), origin: origin) }
        let store = CompanionDeviceStore(keychain: InMemoryKeychain())
        for _ in 0..<5 {
            let request = try store.start(input(), origin: origin)
            store.reject(requestID: request.requestID)
        }
        #expect(throws: CompanionPairingError.self) { try store.start(input(), origin: origin) }
    }

    @Test("发现不泄露账户与凭据，普通网页不能发起配对，JSON 字段符合浏览器契约")
    func httpBoundaryAndRevokedToken() async throws {
        let keychain = InMemoryKeychain()
        let store = CompanionDeviceStore(keychain: keychain)
        let defaults = try #require(UserDefaults(suiteName: "CompanionPairing.\(UUID().uuidString)"))
        let server = CompanionLocalServer(
            configuration: CompanionConfiguration(localAPIKeyStore: StarcatLocalAPIKeyStore(keychain: keychain), defaults: defaults),
            pairingStore: store
        )
        let discovery = await server.handle(http("GET", "/plugin/v1/discover", origin: origin))
        #expect(status(discovery) == 200)
        let discoveryBody = try body(discovery)
        #expect(discoveryBody["product"] as? String == "starcat")
        #expect(discoveryBody["token"] == nil)
        #expect(discoveryBody["account"] == nil)
        let payload = try JSONEncoder().encode(input())
        let denied = await server.handle(http("POST", "/plugin/v1/pairing/start", origin: "https://github.com", body: payload))
        #expect(status(denied) == 403)
        let started = await server.handle(http("POST", "/plugin/v1/pairing/start", origin: origin, body: payload))
        #expect(status(started) == 200)
        let response = try body(started)
        let requestID = try #require(response["request_id"] as? String)
        let secret = try #require(response["claim_secret"] as? String)
        store.approve(requestID: requestID)
        let claim = CompanionPairingClaim(requestID: requestID, claimSecret: secret)
        let approved = await server.handle(http("POST", "/plugin/v1/pairing/poll", origin: origin, body: try JSONEncoder().encode(claim)))
        let token = try #require(try body(approved)["token"] as? String)
        #expect(status(await server.handle(http("GET", "/plugin/v1/ping", origin: origin, token: token))) == 200)
        let deviceID = try #require(store.devices.first?.id)
        try store.revoke(deviceID: deviceID)
        #expect(status(await server.handle(http("GET", "/plugin/v1/ping", origin: origin, token: token))) == 401)
        #expect(!CompanionLocalServer.isExtensionOrigin("chrome-extension://fixture.evil/path"))
    }

    @Test("撤销只终止匹配设备的事件流，停止服务时关闭全部流")
    func eventStreamRevocation() {
        let hub = CompanionEventHub()
        var firstClosed = false
        var secondClosed = false
        _ = hub.addClient(repoID: nil, deviceID: "first", disconnect: { firstClosed = true }) { _ in }
        _ = hub.addClient(repoID: nil, deviceID: "second", disconnect: { secondClosed = true }) { _ in }
        hub.disconnectDevice("first")
        #expect(firstClosed)
        #expect(!secondClosed)
        hub.disconnectAll()
        #expect(secondClosed)
    }

    private func http(_ method: String, _ path: String, origin: String, token: String? = nil, body: Data = Data()) -> Data {
        var header = "\(method) \(path) HTTP/1.1\r\nOrigin: \(origin)\r\nContent-Type: application/json\r\n"
        if let token { header += "Authorization: Bearer \(token)\r\n" }
        header += "Content-Length: \(body.count)\r\n\r\n"
        return Data(header.utf8) + body
    }

    private func status(_ data: Data) -> Int {
        Int(String(decoding: data, as: UTF8.self).split(separator: " ").dropFirst().first ?? "") ?? 0
    }

    private func body(_ data: Data) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        let json = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
