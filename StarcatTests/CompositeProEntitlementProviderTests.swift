//
//  CompositeProEntitlementProviderTests.swift
//  StarcatTests
//
//  多渠道 Pro 权益聚合单测。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CompositeProEntitlementProvider")
@MainActor
struct CompositeProEntitlementProviderTests {

    @Test("没有 active 权益时返回 inactive")
    func returnsInactiveWhenNoProviderIsActive() {
        let entitlement = CompositeProEntitlementProvider.bestEntitlement(from: [.inactive])

        #expect(entitlement == .inactive)
    }

    @Test("任一 Direct License active 即授予 Pro")
    func grantsProWhenDirectLicenseIsActive() {
        let direct = ProEntitlement(
            isActive: true,
            productID: "starcat.pro.direct",
            expirationDate: nil,
            verifiedAt: Date(timeIntervalSince1970: 1),
            source: .directLicense
        )

        let entitlement = CompositeProEntitlementProvider.bestEntitlement(from: [.inactive, direct])

        #expect(entitlement.isActive)
        #expect(entitlement.source == .directLicense)
    }

    @Test("多个 active 权益选择过期时间最晚的来源")
    func choosesLatestExpiration() {
        let storeKit = ProEntitlement(
            isActive: true,
            productID: "storekit.monthly",
            expirationDate: Date(timeIntervalSince1970: 100),
            verifiedAt: Date(timeIntervalSince1970: 1),
            source: .storeKit
        )
        let direct = ProEntitlement(
            isActive: true,
            productID: "direct.yearly",
            expirationDate: Date(timeIntervalSince1970: 200),
            verifiedAt: Date(timeIntervalSince1970: 1),
            source: .directLicense
        )

        let entitlement = CompositeProEntitlementProvider.bestEntitlement(from: [storeKit, direct])

        #expect(entitlement.productID == "direct.yearly")
        #expect(entitlement.source == .directLicense)
    }
}

@Suite("DirectLicenseSnapshot")
struct DirectLicenseSnapshotTests {

    @Test("active 快照转换为 Direct Pro 权益")
    func activeSnapshotGrantsProEntitlement() {
        let snapshot = DirectLicenseSnapshot(
            status: .active,
            provider: .creem,
            productID: "starcat.pro.direct",
            licenseKeySuffix: "ABCD",
            expiresAt: nil,
            validatedAt: Date(timeIntervalSince1970: 10)
        )

        let entitlement = snapshot.proEntitlement()

        #expect(entitlement.isActive)
        #expect(entitlement.source == .directLicense)
        #expect(entitlement.productID == "starcat.pro.direct")
    }

    @Test("revoked 快照转换为 inactive 权益")
    func revokedSnapshotDoesNotGrantPro() {
        let snapshot = DirectLicenseSnapshot(
            status: .revoked,
            provider: .creem,
            productID: "starcat.pro.direct",
            licenseKeySuffix: "ABCD",
            expiresAt: nil,
            validatedAt: Date(timeIntervalSince1970: 10)
        )

        let entitlement = snapshot.proEntitlement()

        #expect(entitlement.isActive == false)
        #expect(entitlement.source == .none)
    }
}
