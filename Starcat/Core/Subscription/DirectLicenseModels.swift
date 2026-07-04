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

/// License API 返回的标准化授权快照。
struct DirectLicenseSnapshot: Codable, Equatable, Sendable {
    var status: DirectLicenseStatus
    var provider: DirectLicenseProviderID
    var productID: String?
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
    var deviceID: String
    var appVersion: String
}

struct DirectLicenseDeactivationRequest: Codable, Equatable, Sendable {
    var deviceID: String
}
