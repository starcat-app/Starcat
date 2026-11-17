//
//  CompanionDeviceStore.swift
//  Starcat
//
//  浏览器六位码配对与逐设备凭据。与 MCP 共用 KeychainManaging 存储机制，
//  使用独立 service 和 Companion 范围，不改变 MCP 邀请或浏览器原有权益。
//

import Foundation
import Observation
import Security

/// 扩展配置内的随机实例 ID 仅用于识别；真正鉴权依赖 App 签发的随机 token。
struct CompanionPairedDevice: Codable, Identifiable, Sendable {
    let id: String
    let instanceID: String
    let browser: String
    var name: String
    let pairedAt: Date
    var lastSeenAt: Date?
    let scope: String
    /// 旧 Keychain 记录没有版本；保持可选以保留已授权浏览器，不推测历史版本。
    var browserVersion: String? = nil

    var browserDescription: String {
        let browserName = browser == "safari" ? "Safari" : "Chrome"
        guard let browserVersion, !browserVersion.isEmpty else { return browserName }
        return "\(browserName) \(browserVersion)"
    }
}

/// 这份快照同时驱动 App 核对界面与服务端批准，避免批准已经替换的请求。
struct CompanionPairingApproval: Identifiable, Sendable {
    let id: String
    let browser: String
    let name: String
    let code: String
    let expiresAt: Date
    var browserVersion: String? = nil
}

struct CompanionPairingStart: Codable, Sendable {
    let instanceID: String
    let browser: String
    let name: String
    var browserVersion: String? = nil

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case browserVersion = "browser_version"
        case browser, name
    }
}

struct CompanionPairingClaim: Codable, Sendable {
    let requestID: String
    let claimSecret: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case claimSecret = "claim_secret"
    }
}

struct CompanionPairingReceipt: Codable, Sendable {
    let requestID: String
    let claimSecret: String
    let code: String
    let expiresAt: String
    let pollInterval: Int
}

struct CompanionPairingResult: Codable, Sendable {
    let status: String
    var deviceID: String? = nil
    var token: String? = nil
    var scope: String? = nil
}

enum CompanionPairingError: Error {
    case invalidRequest
    case busy
    case rateLimited
    case unauthorized
}

/// MainActor 串行管理批准、一次领取与撤销。请求只在内存中保留，App 重启必须重新配对；
/// 长期凭据只进 Keychain，不进入 UserDefaults、数据库、日志或发现响应。
@MainActor
@Observable
final class CompanionDeviceStore {
    static let shared = CompanionDeviceStore()
    static let lifetime: TimeInterval = 120
    private static let serviceID = "starcat.companion.paired-devices"

    private struct Record: Codable {
        var device: CompanionPairedDevice
        let token: String
    }

    private struct Request {
        let approval: CompanionPairingApproval
        let instanceID: String
        let origin: String
        let secret: String
        var state = "pending"
        var deviceID: String?
    }

    private let keychain: any KeychainManaging
    private let now: () -> Date
    private var records: [Record]
    private var requests: [String: Request] = [:]
    private var recentRequests: [Date] = []
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored var onRevoke: ((String) -> Void)?
    private(set) var pendingApproval: CompanionPairingApproval?
    private(set) var approvalFailed = false

    init(
        keychain: any KeychainManaging = KeychainManager.shared,
        now: @escaping () -> Date = Date.init,
        loadStoredCredentials: Bool = !TestEnvironment.isRunning
    ) {
        self.keychain = keychain
        self.now = now
        if loadStoredCredentials,
           let value = try? keychain.loadServiceAPIKey(forService: Self.serviceID),
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    var devices: [CompanionPairedDevice] {
        records.map(\.device).sorted { $0.pairedAt > $1.pairedAt }
    }

    /// 只有显式连接才创建请求。一个待核对请求与每分钟五次的进程级限额足以抑制弹窗刷屏，
    /// 不把自报浏览器名称、实例 ID 或 Origin 当作已经认证的身份。
    func start(_ input: CompanionPairingStart, origin: String) throws -> CompanionPairingReceipt {
        expireRequests()
        guard UUID(uuidString: input.instanceID) != nil,
              ["chrome", "safari"].contains(input.browser),
              !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.name.count <= 128,
              (input.browserVersion?.count ?? 0) <= 64 else {
            throw CompanionPairingError.invalidRequest
        }
        guard pendingApproval == nil else { throw CompanionPairingError.busy }
        recentRequests.removeAll { now().timeIntervalSince($0) >= 60 }
        guard recentRequests.count < 5 else { throw CompanionPairingError.rateLimited }
        recentRequests.append(now())
        let requestID = UUID().uuidString.lowercased()
        let secret = try Self.randomToken()
        let activeCodes = Set(requests.values.filter { $0.approval.expiresAt > now() }.map(\.approval.code))
        var code: String
        repeat { code = String(format: "%06d", Int.random(in: 0...999_999)) } while activeCodes.contains(code)
        let approval = CompanionPairingApproval(
            id: requestID, browser: input.browser, name: input.name,
            code: code, expiresAt: now().addingTimeInterval(Self.lifetime),
            browserVersion: input.browserVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        requests[requestID] = Request(
            approval: approval, instanceID: input.instanceID, origin: origin, secret: secret
        )
        pendingApproval = approval
        approvalFailed = false
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.lifetime))
            guard !Task.isCancelled else { return }
            self?.expireRequests()
        }
        return CompanionPairingReceipt(
            requestID: requestID, claimSecret: secret, code: code,
            expiresAt: ISO8601DateFormatter.shared.string(from: approval.expiresAt), pollInterval: 2
        )
    }

    /// 批准必须绑定当前展示请求。Keychain 保存失败时保留待批准状态，不能先向浏览器宣告成功。
    func approve(requestID: String) {
        expireRequests()
        guard let approval = pendingApproval, approval.id == requestID,
              var request = requests[requestID], request.state == "pending" else { return }
        do {
            let device = CompanionPairedDevice(
                id: UUID().uuidString.lowercased(), instanceID: request.instanceID,
                browser: approval.browser, name: approval.name, pairedAt: now(),
                lastSeenAt: nil, scope: "companion", browserVersion: approval.browserVersion
            )
            let record = Record(device: device, token: try Self.randomToken())
            try persist(records + [record])
            records.append(record)
            request.deviceID = device.id
            request.state = "approved"
            requests[requestID] = request
            pendingApproval = nil
            approvalFailed = false
        } catch {
            approvalFailed = true
        }
    }

    func reject(requestID: String) {
        guard requests[requestID]?.state == "pending" else { return }
        requests[requestID]?.state = "rejected"
        if pendingApproval?.id == requestID { pendingApproval = nil }
    }

    /// 领取凭据有 256 bit 熵且绑定请求和来源；六位码、request ID 或实例 ID 均不能单独领 token。
    func poll(_ claim: CompanionPairingClaim, origin: String) throws -> CompanionPairingResult {
        expireRequests()
        guard var request = requests[claim.requestID],
              request.origin == origin, Self.equals(request.secret, claim.claimSecret) else {
            throw CompanionPairingError.unauthorized
        }
        guard request.approval.expiresAt > now() else { return .init(status: "expired") }
        guard request.state == "approved" else { return .init(status: request.state) }
        guard let record = records.first(where: { $0.device.id == request.deviceID }) else {
            return .init(status: "revoked")
        }
        request.state = "claimed"
        requests[claim.requestID] = request
        return .init(status: "approved", deviceID: record.device.id, token: record.token, scope: "companion")
    }

    func cancel(_ claim: CompanionPairingClaim, origin: String) throws {
        expireRequests()
        guard let request = requests[claim.requestID],
              request.origin == origin, Self.equals(request.secret, claim.claimSecret) else {
            throw CompanionPairingError.unauthorized
        }
        if (request.state == "approved" || request.state == "claimed"), let deviceID = request.deviceID {
            try revoke(deviceID: deviceID)
        }
        guard ["pending", "approved", "claimed"].contains(request.state) else { return }
        requests[claim.requestID]?.state = "cancelled"
        if pendingApproval?.id == claim.requestID { pendingApproval = nil }
    }

    /// 先成功保存撤销结果，再终止该设备事件流；持久化失败不得显示“已取消配对”。
    func revoke(deviceID: String) throws {
        let next = records.filter { $0.device.id != deviceID }
        try persist(next)
        records = next
        onRevoke?(deviceID)
    }

    func rename(deviceID: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { throw CompanionPairingError.invalidRequest }
        var next = records
        guard let index = next.firstIndex(where: { $0.device.id == deviceID }) else { return }
        next[index].device.name = trimmed
        try persist(next)
        records = next
    }

    func authorizedDevice(token: String) -> CompanionPairedDevice? {
        guard let index = records.firstIndex(where: { Self.equals($0.token, token) }) else { return nil }
        if records[index].device.lastSeenAt.map({ now().timeIntervalSince($0) >= 60 }) ?? true {
            var next = records
            next[index].device.lastSeenAt = now()
            if (try? persist(next)) != nil { records = next }
        }
        return records[index].device
    }

    /// 失效请求保留至十分钟便于返回终态，数量由限频约束；已批准但未领取的 token 同步撤销。
    func expireRequests() {
        for (requestID, request) in requests where request.approval.expiresAt <= now() {
            if request.state == "approved", let deviceID = request.deviceID {
                do { try revoke(deviceID: deviceID) } catch { continue }
            }
            if request.state == "pending" || request.state == "approved" {
                requests[requestID]?.state = "expired"
            }
            if pendingApproval?.id == requestID { pendingApproval = nil }
        }
        requests = requests.filter { now().timeIntervalSince($0.value.approval.expiresAt) < 600 }
    }

    func invalidatePendingRequests() {
        for requestID in requests.keys where requests[requestID]?.state == "pending" {
            requests[requestID]?.state = "cancelled"
        }
        pendingApproval = nil
        expiryTask?.cancel()
    }

    private func persist(_ next: [Record]) throws {
        let data = try JSONEncoder().encode(next)
        try keychain.storeServiceAPIKey(String(decoding: data, as: UTF8.self), forService: Self.serviceID)
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CompanionPairingError.invalidRequest
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func equals(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        guard leftBytes.count == rightBytes.count else { return false }
        var difference: UInt8 = 0
        for index in leftBytes.indices { difference |= leftBytes[index] ^ rightBytes[index] }
        return difference == 0
    }
}
