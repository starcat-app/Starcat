//
//  DirectLicenseModels.swift
//  Starcat
//
//  Direct 分发授权 DTO 与领域模型。
//

import Darwin
import Foundation

/// Direct 授权背后的支付/授权 provider。
///
/// 客户端只保存 provider id，不依赖 Creem 的私有语义。后端可以同时接 Creem、
/// Lemon Squeezy 或自建授权系统，只要返回同一套 License 快照即可。
enum DirectLicenseProviderID: String, Codable, Sendable, CaseIterable {
    case creem
    case custom
}

/// Direct License 当前状态。
enum DirectLicenseStatus: String, Codable, Sendable {
    case active
    case inactive
    case expired
    case revoked

    var grantsPro: Bool { self == .active }
}

/// Direct 官网售卖的 checkout 计划。
///
/// rawValue 与 `supports/starcat-license-api` 的 plan alias 对齐，后端再把它映射到真实
/// Creem product id。客户端不携带 Creem product id，避免把支付后台 SKU 暴露给 App。
enum DirectCheckoutPlan: String, Codable, Sendable, CaseIterable {
    case monthly
    case yearly
    case lifetime
}

/// Direct License 在本机运行期的授权状态。
///
/// 这个状态只用于内部诊断和校验调度，不直接展示给用户。用户只看到最终 Pro 是否可用，
/// 网络失败这类中间态不应该打扰正常使用。
enum DirectLicenseRuntimeState: String, Codable, Equatable, Sendable {
    case none
    case localActive
    case verifiedActive
    case revoked
    case expired
}

/// Direct 授权设备的 Mac 硬件类别。
///
/// Creem 只保存客户端提交的实例名，不会识别 Apple 硬件；客户端因此读取 `hw.model`
/// 并归类后写入实例名。无法识别的新机型使用通用 Mac，避免错误地展示成某个具体型号。
enum DirectLicenseDeviceKind: String, Codable, Equatable, Sendable {
    case mac
    case macBookAir
    case macBookPro
    case macMini
    case macStudio
    case iMac
    case macPro

    var instanceNamePrefix: String {
        switch self {
        case .mac: return "Mac"
        case .macBookAir: return "MacBook Air"
        case .macBookPro: return "MacBook Pro"
        case .macMini: return "Mac mini"
        case .macStudio: return "Mac Studio"
        case .iMac: return "iMac"
        case .macPro: return "Mac Pro"
        }
    }

    var systemImageName: String {
        switch self {
        case .macBookAir, .macBookPro: return "laptopcomputer.badge.checkmark"
        case .macMini: return "macmini.badge.checkmark"
        case .macStudio: return "macstudio.badge.checkmark"
        case .iMac: return "imac.badge.checkmark"
        case .macPro: return "macpro.gen3.badge.checkmark"
        case .mac: return "desktopcomputer.badge.checkmark"
        }
    }

    static func currentMac() -> Self {
        guard let identifier = hardwareModelIdentifier() else { return .mac }
        return forHardwareModelIdentifier(identifier)
    }

    static func forHardwareModelIdentifier(_ identifier: String) -> Self {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        if identifier.hasPrefix("MacBookAir") { return .macBookAir }
        if identifier.hasPrefix("MacBookPro") { return .macBookPro }
        if identifier.hasPrefix("Macmini") { return .macMini }
        if identifier.hasPrefix("iMac") { return .iMac }
        if identifier.hasPrefix("MacPro") { return .macPro }

        switch identifier {
        // Apple silicon 的部分机型使用 `Mac<generation>,<variant>`，需要显式映射。
        case "Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14":
            return .macStudio
        case "Mac14,3", "Mac16,10":
            return .macMini
        case "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13":
            return .macBookAir
        case "Mac14,5", "Mac14,6", "Mac14,7", "Mac15,3", "Mac15,6", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11", "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8":
            return .macBookPro
        case "Mac14,4":
            return .iMac
        case "Mac14,8":
            return .macPro
        default:
            return .mac
        }
    }

    private static func hardwareModelIdentifier() -> String? {
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        return buffer.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress,
                  sysctlbyname("hw.model", baseAddress, &size, nil, 0) == 0
            else { return nil }
            return String(cString: baseAddress)
        }
    }
}

/// Direct License 远程校验记录。
///
/// 与授权码一起存在本机安全存储里，用来控制后台校验频率和避免网络抖动误伤 Pro。
/// `lastErrorCode` 仅供日志/诊断使用，不能作为 UI 文案直接暴露给用户。
struct DirectLicenseValidationRecord: Equatable, Sendable {
    var plan: DirectCheckoutPlan? = nil
    var runtimeState: DirectLicenseRuntimeState
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var lastErrorCode: String?
    var lastRemoteStatus: DirectLicenseStatus?

    static let empty = DirectLicenseValidationRecord(
        plan: nil,
        runtimeState: .none,
        lastAttemptAt: nil,
        lastSuccessAt: nil,
        lastFailureAt: nil,
        lastErrorCode: nil,
        lastRemoteStatus: nil
    )
}

/// 创建 Direct checkout 的请求体。
struct DirectCheckoutRequest: Codable, Equatable, Sendable {
    var plan: DirectCheckoutPlan
    var customerEmail: String?
    var successURL: String?
    var requestID: String?
}

/// Direct checkout / customer portal 返回的可打开 URL。
struct DirectPaymentURLResponse: Codable, Equatable, Sendable {
    var provider: DirectLicenseProviderID
    var url: String
    var id: String?
}

/// 创建支付平台 customer portal 的请求体。
///
/// 只提交本机已激活的授权码与实例；客户归属由 License API 依据已验签 checkout 映射解析，
/// 客户端不保存或传递 `customerID`。
struct DirectCustomerPortalRequest: Codable, Equatable, Sendable {
    var licenseKey: String
    var instanceID: String
}

/// 取消 Direct 月订阅的请求体。
struct DirectCancelSubscriptionRequest: Codable, Equatable, Sendable {
    var subscriptionID: String
    var mode: String?
    var onExecute: String?
}

/// Direct 订阅生命周期快照。
struct DirectSubscriptionSnapshot: Codable, Equatable, Sendable {
    var provider: DirectLicenseProviderID
    var subscriptionID: String
    var status: String?
    var productID: String?
    var currentPeriodEnd: String?
    var canceledAt: String?
}

/// License API 返回的标准化授权快照。
struct DirectLicenseSnapshot: Codable, Equatable, Sendable {
    var status: DirectLicenseStatus
    var provider: DirectLicenseProviderID
    var plan: DirectCheckoutPlan?
    var productID: String?
    var instanceID: String?
    var activationUsed: Int? = nil
    var activationLimit: Int? = nil
    var licenseKeySuffix: String?
    var expiresAt: Date?
    var validatedAt: Date
    var devices: [DirectLicenseDevice]?

    func proEntitlement() -> ProEntitlement {
        ProEntitlement(
            isActive: status.grantsPro,
            productID: productID,
            expirationDate: expiresAt,
            verifiedAt: validatedAt,
            source: status.grantsPro ? .directLicense : .none
        )
    }
}

struct DirectLicenseDevice: Codable, Equatable, Identifiable, Sendable {
    var instanceID: String
    var name: String?
    var deviceKind: DirectLicenseDeviceKind?
    var status: String
    var createdAt: Date?
    var isCurrentDevice: Bool

    var id: String { instanceID }
}

struct DirectLicenseActivationRequest: Codable, Equatable, Sendable {
    var licenseKey: String
    var deviceID: String
    var appVersion: String
}

struct DirectLicenseValidationRequest: Codable, Equatable, Sendable {
    var licenseKey: String
    var instanceID: String
    var deviceID: String
    var appVersion: String
}

struct DirectLicenseDeactivationRequest: Codable, Equatable, Sendable {
    var licenseKey: String
    var instanceID: String
    var deviceID: String
}

struct DirectLicenseDevicesRequest: Codable, Equatable, Sendable {
    var licenseKey: String
    var instanceID: String
    var deviceID: String
}
