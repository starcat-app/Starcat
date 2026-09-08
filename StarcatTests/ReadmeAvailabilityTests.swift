//
//  ReadmeAvailabilityTests.swift
//  StarcatTests
//
//  `ReadmeAvailability` 集合 API 的轻量单测。
//
//  2026-09-09：自动 load 不再用本类短路网络，但 mark / clear / query 仍须正确，
//  避免其它读者读到过期「已知缺失」标记。
//

import Testing
@testable import Starcat

@Suite("ReadmeAvailability")
@MainActor
struct ReadmeAvailabilityTests {

    @Test("mark / clear / isKnownNotFound 读写一致")
    func markAndClear() {
        let availability = ReadmeAvailability()
        #expect(availability.isKnownNotFound(repoId: 42) == false)

        availability.markNotFound(repoId: 42)
        #expect(availability.isKnownNotFound(repoId: 42) == true)
        #expect(availability.isKnownNotFound(repoId: 7) == false)

        availability.clearNotFound(repoId: 42)
        #expect(availability.isKnownNotFound(repoId: 42) == false)
    }
}
