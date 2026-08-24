//
//  GrowthAttributionTests.swift
//  StarcatTests
//
//  增长归因文案与私有仓库边界测试。
//

import XCTest
@testable import Starcat

final class GrowthAttributionTests: XCTestCase {
    func testPublicRepositoryShareTextContainsSharePageAndSourceRepository() {
        let repo = makeRepo(isPrivate: false)

        let text = GrowthAttribution.repositoryShareText(
            title: "Star history for starcat-app/Starcat",
            details: ["Current stars: 100"],
            repo: repo
        )

        XCTAssertTrue(text.contains("https://starcat.ink/r/starcat-app/Starcat"))
        XCTAssertTrue(text.contains(AppWebsiteLinks.sourceRepository.absoluteString))
        XCTAssertTrue(text.contains(GrowthAttribution.signature))
    }

    func testPrivateRepositoryShareTextOmitsPublicSharePage() {
        let repo = makeRepo(isPrivate: true)

        let text = GrowthAttribution.repositoryShareText(
            title: "Repo Health for private/example",
            details: ["Score: 90/100"],
            repo: repo
        )

        XCTAssertFalse(text.contains("starcat.ink/r/"))
        XCTAssertTrue(text.contains(AppWebsiteLinks.sourceRepository.absoluteString))
    }

    func testAggregateShareTextContainsSourceRepository() {
        let text = GrowthAttribution.aggregateShareText(
            title: "My technology stack",
            details: ["Swift: 12", "Go: 8"]
        )

        XCTAssertTrue(text.contains("Swift: 12"))
        XCTAssertTrue(text.contains(AppWebsiteLinks.sourceRepository.absoluteString))
    }

    private func makeRepo(isPrivate: Bool) -> Repo {
        Repo(
            id: 1,
            owner: isPrivate ? "private" : "starcat-app",
            name: isPrivate ? "example" : "Starcat",
            fullName: isPrivate ? "private/example" : "starcat-app/Starcat",
            description: nil,
            language: "Swift",
            starsCount: 100,
            forksCount: 10,
            watchersCount: 5,
            topics: nil,
            license: "MIT",
            homepage: nil,
            htmlUrl: "https://github.com/example/repo",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }
}
