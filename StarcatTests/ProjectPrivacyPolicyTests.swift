//
//  ProjectPrivacyPolicyTests.swift
//  StarcatTests
//
//  证明 Private 项目不会获得公共服务、公开分享或 Universal Link 放行。
//

import Testing
@testable import Starcat

@Suite("ProjectPrivacyPolicy")
struct ProjectPrivacyPolicyTests {
    @Test("Private 项目禁止所有公共出口")
    func privateRepoBlocksPublicDestinations() {
        let repo = makeRepo(isPrivate: true)

        #expect(!ProjectPrivacyPolicy.allowsPublicService(for: repo))
        #expect(!ProjectPrivacyPolicy.allowsPublicShare(for: repo))
        #expect(!ProjectPrivacyPolicy.allowsUniversalLink(for: repo))
        #expect(!ProjectPrivacyPolicy.allowsDiscoveryLookup(for: repo))
        #expect(!ProjectPrivacyPolicy.allowsExternalSearchContext(for: repo))
    }

    @Test("Public 项目保留既有公开能力")
    func publicRepoAllowsPublicDestinations() {
        let repo = makeRepo(isPrivate: false)

        #expect(ProjectPrivacyPolicy.allowsPublicService(for: repo))
        #expect(ProjectPrivacyPolicy.allowsPublicShare(for: repo))
        #expect(ProjectPrivacyPolicy.allowsUniversalLink(for: repo))
        #expect(ProjectPrivacyPolicy.allowsDiscoveryLookup(for: repo))
        #expect(ProjectPrivacyPolicy.allowsExternalSearchContext(for: repo))
    }

    @Test("项目关系、状态、私有缓存和凭据保持设备本地")
    func projectLocalDataIsExcludedFromCloudKitAndDefaultExport() {
        for kind in UserProjectLocalDataKind.allCases {
            #expect(!UserProjectDataBoundary.allowsCloudKit(kind))
            #expect(!UserProjectDataBoundary.allowsDefaultExport(kind))
        }
    }

    @Test("默认仓库导出没有我的项目 scope")
    func defaultRepositoryExportScopesExcludeMyProjects() {
        #expect(
            Set(RepositoryExportScope.allCases.map(\.rawValue))
                == Set(["starred", "library"])
        )
    }

    private func makeRepo(isPrivate: Bool) -> Repo {
        Repo(
            id: 42,
            owner: "private-owner",
            name: "private-repo",
            fullName: "private-owner/private-repo",
            description: nil,
            language: "Swift",
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/private-owner/private-repo",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
            isFork: false,
            isArchived: false,
            isStarred: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }
}
