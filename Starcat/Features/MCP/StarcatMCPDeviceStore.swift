//
//  StarcatMCPDeviceStore.swift
//  Starcat
//
//  外部 CLI 的一次性配对与逐设备凭据存储。
//
//  安全约束：
//  - invitation secret 只保存在内存，五分钟失效且请求后立即消费；
//  - 长期 token 按设备保存在 Starcat 本机加密凭据文件；
//  - CLI 兑换邀请后仍要经过 App 内确认，避免复制内容被旁路进程抢先兑换；
//  - 对外模型永远不包含其它设备 token。
//

import Foundation
import Observation
import Security

struct StarcatMCPPairingExchangeRequest: Codable, Sendable {
    let secret: String
    let device_name: String
    let platform: String
    let architecture: String
    let cli_version: String
}

struct StarcatMCPPairingExchangeResponse: Codable, Sendable {
    let device_id: String
    let token: String
    let app_version: String
    let protocol_version: String
}

struct StarcatMCPPairedDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let platform: String
    let architecture: String
    let cliVersion: String
    let pairedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case platform
        case architecture
        case cliVersion = "cli_version"
        case pairedAt = "paired_at"
    }
}

struct StarcatMCPPairingApproval: Identifiable, Equatable {
    let id = UUID()
    let deviceName: String
    let platform: String
    let architecture: String
    let cliVersion: String
}

enum StarcatMCPPairingError: LocalizedError {
    case invalidInvitation
    case invitationExpired
    case approvalAlreadyPending
    case rejected
    case persistenceFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidInvitation:
            return String.l10n("settings.mcp.pairing.error.invalidInvitation")
        case .invitationExpired:
            return String.l10n("settings.mcp.pairing.error.expired")
        case .approvalAlreadyPending:
            return String.l10n("settings.mcp.pairing.error.pending")
        case .rejected:
            return String.l10n("settings.mcp.pairing.error.rejected")
        case .persistenceFailed(let error):
            return error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class StarcatMCPDeviceStore {
    static let protocolVersion = "1"

    private struct Invitation {
        let expiresAt: Date
    }

    private struct CredentialRecord: Codable {
        let device: StarcatMCPPairedDevice
        let token: String
    }

    private static let credentialServiceID = "mcp-device-credentials-v1"
    private static let invitationLifetime: TimeInterval = 5 * 60
    private static let approvalLifetimeNanoseconds: UInt64 = 2 * 60 * 1_000_000_000

    private let keychain: any KeychainManaging
    private var records: [CredentialRecord]
    private var invitations: [String: Invitation] = [:]
    private var approvalContinuation: CheckedContinuation<StarcatMCPPairingExchangeResponse, Error>?
    private var approvalTimeoutTask: Task<Void, Never>?

    private(set) var pendingApproval: StarcatMCPPairingApproval?

    init(keychain: any KeychainManaging = KeychainManager.shared) {
        self.keychain = keychain
        self.records = Self.loadRecords(keychain: keychain)
    }

    var devices: [StarcatMCPPairedDevice] {
        records.map(\.device).sorted { $0.pairedAt > $1.pairedAt }
    }

    /// 创建可复制给外部 Agent 的 opaque URI。endpoint 和证书指纹属于连接元数据，
    /// 一次性 secret 才是短期敏感值，因此不得写日志或持久化。
    func createInvitation(endpoint: String, certificateFingerprint: String?) throws -> String {
        cleanupExpiredInvitations()
        let secret = try Self.randomToken(byteCount: 32)
        invitations[secret] = Invitation(expiresAt: Date().addingTimeInterval(Self.invitationLifetime))

        var components = URLComponents()
        components.scheme = "starcat-pair"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.protocolVersion),
            URLQueryItem(name: "endpoint", value: endpoint),
            URLQueryItem(name: "secret", value: secret)
        ]
        if let certificateFingerprint, !certificateFingerprint.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "fingerprint", value: certificateFingerprint))
        }
        guard let value = components.string else {
            throw StarcatMCPPairingError.invalidInvitation
        }
        return value
    }

    /// HTTP exchange 会挂起到用户在 Starcat sheet 中确认；因此设备元数据可见、可拒绝，
    /// 而 invitation secret 被其它进程截获时也不能静默取得长期 token。
    func exchange(_ request: StarcatMCPPairingExchangeRequest) async throws -> StarcatMCPPairingExchangeResponse {
        cleanupExpiredInvitations()
        guard Self.isValidMetadata(request.device_name, maximumLength: 128),
              Self.isValidMetadata(request.platform, maximumLength: 32),
              Self.isValidMetadata(request.architecture, maximumLength: 32),
              Self.isValidMetadata(request.cli_version, maximumLength: 64) else {
            throw StarcatMCPPairingError.invalidInvitation
        }
        guard let invitation = invitations.removeValue(forKey: request.secret) else {
            throw StarcatMCPPairingError.invalidInvitation
        }
        guard invitation.expiresAt > Date() else {
            throw StarcatMCPPairingError.invitationExpired
        }
        guard pendingApproval == nil, approvalContinuation == nil else {
            throw StarcatMCPPairingError.approvalAlreadyPending
        }

        pendingApproval = StarcatMCPPairingApproval(
            deviceName: request.device_name,
            platform: request.platform,
            architecture: request.architecture,
            cliVersion: request.cli_version
        )

        return try await withCheckedThrowingContinuation { continuation in
            approvalContinuation = continuation
            approvalTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.approvalLifetimeNanoseconds)
                guard !Task.isCancelled else { return }
                self?.rejectPendingPairing()
            }
        }
    }

    func approvePendingPairing() {
        guard let approval = pendingApproval, let continuation = approvalContinuation else { return }
        do {
            let deviceID = UUID().uuidString.lowercased()
            let token = try Self.randomToken(byteCount: 32)
            let device = StarcatMCPPairedDevice(
                id: deviceID,
                name: approval.deviceName,
                platform: approval.platform,
                architecture: approval.architecture,
                cliVersion: approval.cliVersion,
                pairedAt: Date()
            )
            records.append(CredentialRecord(device: device, token: token))
            do {
                try persistRecords()
            } catch {
                records.removeAll { $0.device.id == deviceID }
                throw StarcatMCPPairingError.persistenceFailed(error)
            }
            clearPendingApproval()
            continuation.resume(returning: StarcatMCPPairingExchangeResponse(
                device_id: deviceID,
                token: token,
                app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                protocol_version: Self.protocolVersion
            ))
        } catch {
            clearPendingApproval()
            continuation.resume(throwing: error)
        }
    }

    func rejectPendingPairing() {
        guard let continuation = approvalContinuation else {
            clearPendingApproval()
            return
        }
        clearPendingApproval()
        continuation.resume(throwing: StarcatMCPPairingError.rejected)
    }

    func revoke(deviceID: String) throws {
        let previous = records
        records.removeAll { $0.device.id == deviceID }
        do {
            try persistRecords()
        } catch {
            records = previous
            throw error
        }
    }

    func invalidatePendingPairing() {
        invitations.removeAll()
        rejectPendingPairing()
    }

    func isAuthorized(token: String) -> Bool {
        records.contains { Self.constantTimeEquals($0.token, token) }
    }

    private func clearPendingApproval() {
        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil
        approvalContinuation = nil
        pendingApproval = nil
    }

    private func cleanupExpiredInvitations() {
        let now = Date()
        invitations = invitations.filter { $0.value.expiresAt > now }
    }

    private func persistRecords() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        guard let value = String(data: data, encoding: .utf8) else {
            throw StarcatMCPPairingError.invalidInvitation
        }
        try keychain.storeServiceAPIKey(value, forService: Self.credentialServiceID)
    }

    private static func loadRecords(keychain: any KeychainManaging) -> [CredentialRecord] {
        guard let value = try? keychain.loadServiceAPIKey(forService: credentialServiceID),
              let data = value.data(using: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CredentialRecord].self, from: data)) ?? []
    }

    private static func randomToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StarcatMCPPairingError.invalidInvitation
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func isValidMetadata(_ value: String, maximumLength: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumLength
    }
}
