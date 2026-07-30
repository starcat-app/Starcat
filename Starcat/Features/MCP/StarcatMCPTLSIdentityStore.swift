//
//  StarcatMCPTLSIdentityStore.swift
//  Starcat
//
//  为可信网络 MCP listener 生成并持久化每台 Mac 独有的自签名 TLS identity。
//
//  不使用共享证书，也不调用外部 openssl 进程：App Sandbox 内通过 Security.framework
//  生成 P-256 私钥，再构造最小 X.509 证书并用同一私钥签名。CLI 不依赖公共 CA，
//  而是 pin 一次性 invitation 中的 SHA-256 指纹。
//

import CryptoKit
import Foundation
import Security

/// `SecIdentity` 是不可变 Core Foundation 引用，生成后只交给 Network.framework。
/// 用 wrapper 明确跨 actor 传递边界，避免把可变 Keychain 操作本身带出后台任务。
struct StarcatMCPTLSIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificateFingerprint: String
}

enum StarcatMCPTLSIdentityError: LocalizedError {
    case security(OSStatus)
    case invalidKey
    case invalidCertificate
    case signingFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .security(let status):
            return "TLS identity Security.framework error: \(status)"
        case .invalidKey:
            return "Unable to create the Starcat TLS private key."
        case .invalidCertificate:
            return "Unable to create the Starcat TLS certificate."
        case .signingFailed(let error):
            return "Unable to sign the Starcat TLS certificate: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}

final class StarcatMCPTLSIdentityStore {
    private static let keyTag = Data("com.starcat.mcp.tls.p256.v1".utf8)
    private static let certificateLabel = "com.starcat.mcp.tls.certificate.v1"

    func loadOrCreate() throws -> StarcatMCPTLSIdentity {
        if let existing = try loadExisting() {
            return existing
        }
        return try create()
    }

    private func loadExisting() throws -> StarcatMCPTLSIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.certificateLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let certificate = item as! SecCertificate? else {
            throw StarcatMCPTLSIdentityError.security(status)
        }
        return try makeIdentity(certificate: certificate)
    }

    private func create() throws -> StarcatMCPTLSIdentity {
        let privateKey = try loadOrCreatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw StarcatMCPTLSIdentityError.invalidKey
        }
        let certificateData = try Self.makeCertificateDER(privateKey: privateKey, publicKey: publicKey)
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw StarcatMCPTLSIdentityError.invalidCertificate
        }
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.certificateLabel,
            kSecValueRef: certificate
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw StarcatMCPTLSIdentityError.security(status)
        }
        return try makeIdentity(certificate: certificate)
    }

    /// certificate 写入前进程被终止时，永久 private key 可能已经存在。先复用该 key，
    /// 避免下一次启动因 `errSecDuplicateItem` 永久无法恢复 TLS identity。
    private func loadOrCreatePrivateKey() throws -> SecKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: Self.keyTag,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let key = item as! SecKey? {
            return key
        }
        guard status == errSecItemNotFound else {
            throw StarcatMCPTLSIdentityError.security(status)
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: Self.keyTag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
            throw StarcatMCPTLSIdentityError.signingFailed(creationError?.takeRetainedValue())
        }
        return key
    }

    private func makeIdentity(certificate: SecCertificate) throws -> StarcatMCPTLSIdentity {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw StarcatMCPTLSIdentityError.security(status)
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
        return StarcatMCPTLSIdentity(identity: identity, certificateFingerprint: fingerprint)
    }

    /// 构造仅用于 pinning 的最小自签名 X.509 v3 certificate。CLI 关闭公共 CA/hostname
    /// 验证并严格比对整个 DER 的 SHA-256，因此这里不声明会随主机名变化的 SAN。
    static func makeCertificateDER(privateKey: SecKey, publicKey: SecKey) throws -> Data {
        var externalError: Unmanaged<CFError>?
        guard let publicData = SecKeyCopyExternalRepresentation(publicKey, &externalError) as Data? else {
            throw StarcatMCPTLSIdentityError.signingFailed(externalError?.takeRetainedValue())
        }

        let signatureAlgorithm = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))
        let publicKeyAlgorithm = DER.sequence(
            DER.oid([1, 2, 840, 10045, 2, 1]),
            DER.oid([1, 2, 840, 10045, 3, 1, 7])
        )
        let name = DER.sequence(
            DER.set(DER.sequence(DER.oid([2, 5, 4, 3]), DER.utf8String("Starcat MCP")))
        )
        let now = Date()
        let validity = DER.sequence(
            DER.utcTime(now.addingTimeInterval(-24 * 60 * 60)),
            DER.utcTime(now.addingTimeInterval(10 * 365 * 24 * 60 * 60))
        )
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw StarcatMCPTLSIdentityError.invalidCertificate
        }
        if serial.allSatisfy({ $0 == 0 }) { serial[15] = 1 }

        let subjectPublicKeyInfo = DER.sequence(publicKeyAlgorithm, DER.bitString(publicData))
        let tbsCertificate = DER.sequence(
            DER.context(tag: 0, content: DER.integer(Data([2]))),
            DER.positiveInteger(Data(serial)),
            signatureAlgorithm,
            name,
            validity,
            name,
            subjectPublicKeyInfo
        )
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &signingError
        ) as Data? else {
            throw StarcatMCPTLSIdentityError.signingFailed(signingError?.takeRetainedValue())
        }
        return DER.sequence(tbsCertificate, signatureAlgorithm, DER.bitString(signature))
    }
}

/// 只覆盖 Starcat 自签名证书需要的 DER primitive，避免引入完整 X.509 依赖。
private enum DER {
    static func sequence(_ values: Data...) -> Data { tagged(0x30, Data(values.joined())) }
    static func set(_ value: Data) -> Data { tagged(0x31, value) }
    static func integer(_ value: Data) -> Data { tagged(0x02, value) }
    static func positiveInteger(_ value: Data) -> Data {
        var bytes = Array(value.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(0x02, Data(bytes))
    }
    static func utf8String(_ value: String) -> Data { tagged(0x0c, Data(value.utf8)) }
    static func bitString(_ value: Data) -> Data { tagged(0x03, Data([0]) + value) }
    static func context(tag: UInt8, content: Data) -> Data { tagged(0xa0 | tag, content) }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: date).utf8))
    }

    static func oid(_ components: [UInt64]) -> Data {
        precondition(components.count >= 2)
        var bytes = [UInt8(components[0] * 40 + components[1])]
        for component in components.dropFirst(2) {
            var value = component
            var encoded = [UInt8(value & 0x7f)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8(value & 0x7f) | 0x80, at: 0)
                value >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return tagged(0x06, Data(bytes))
    }

    private static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
