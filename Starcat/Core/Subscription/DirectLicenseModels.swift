//
//  DirectLicenseModels.swift
//  Starcat
//
//  Direct 分发授权 DTO 与领域模型。
//

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

/// Direct License 远程校验记录。
///
/// 与授权码一起存在本机安全存储里，用来控制后台校验频率和避免网络抖动误伤 Pro。
/// `lastErrorCode` 仅供日志/诊断使用，不能作为 UI 文案直接暴露给用户。
struct DirectLicenseValidationRecord: Equatable, Sendable {
    var plan: DirectCheckoutPlan?
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
struct DirectCustomerPortalRequest: Codable, Equatable, Sendable {
    var customerID: String?
    var email: String?
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
    var customerID: String?
    var currentPeriodEnd: String?
    var canceledAt: String?
}

/// License API 返回的标准化授权快照。
struct DirectLicenseSnapshot: Codable, Equatable, Sendable {
    var status: DirectLicenseStatus
    var provider: DirectLicenseProviderID
    var productID: String?
    var instanceID: String?
    var activationUsed: Int? = nil
    var activationLimit: Int? = nil
    var licenseKeySuffix: String?
    var expiresAt: Date?
    var validatedAt: Date

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
