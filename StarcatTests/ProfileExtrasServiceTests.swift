//
//  ProfileExtrasServiceTests.swift
//  StarcatTests
//
//  验证浮层缓存的独立失败、成功空结果、账号隔离与退出清理，不访问网络或 Keychain。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
struct ProfileExtrasServiceTests {
    /// 各测试使用独立 UserDefaults 域，不读写用户实际资料。
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ProfileExtrasTests.\(UUID().uuidString)")!
    }

    private func user(_ identifier: Int64 = 42) -> GitHubUserDTO {
        GitHubUserDTO(id: identifier, login: "user-\(identifier)", name: nil, avatarUrl: nil)
    }

    /// 服务对外仍使用同步 load；测试只等待真实 loading 完成，不用固定睡眠猜测网络时长。
    private func waitForLoad(_ service: ProfileExtrasService) async throws {
        for _ in 0..<300 {
            if !service.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("资料服务未在测试时限内完成")
    }

    @Test("分区失败保留缓存且强制刷新可清除旧列表")
    func preservesCacheOnFailureAndAcceptsEmptyResults() async throws {
        let api = ProfileExtrasMock()
        let service = ProfileExtrasService(api: api, defaults: makeDefaults())
        service.load(user: user())
        try await waitForLoad(service)
        #expect(service.snapshot.achievements?.count == 1)
        #expect(service.snapshot.organizations?.organizations.count == 1)

        await api.configure(failAchievements: true, empty: true)
        service.load(user: user(), force: true)
        try await waitForLoad(service)
        #expect(service.snapshot.achievements?.count == 1)
        #expect(service.failures == [.achievements])
        #expect(service.snapshot.organizations?.organizations == [])
        #expect(service.snapshot.sponsors?.sponsors == [])

        await api.configure(failAchievements: false, empty: true)
        service.load(user: user(), force: true)
        try await waitForLoad(service)
        #expect(service.snapshot.achievements == [])
    }

    @Test("相同账号复用 TTL 缓存且退出清掉非公开组织")
    func cacheAndResetAreAccountScoped() async throws {
        let api = ProfileExtrasMock()
        let defaults = makeDefaults()
        let service = ProfileExtrasService(api: api, defaults: defaults)
        service.load(user: user())
        try await waitForLoad(service)
        let calls = await api.calls
        service.load(user: user())
        #expect(await api.calls == calls)

        let restored = ProfileExtrasService(api: api, defaults: defaults)
        restored.load(user: user())
        #expect(!restored.isLoading)
        #expect(restored.snapshot == service.snapshot)

        service.reset()
        #expect(service.userID == nil)
        #expect(service.snapshot.organizations == nil)
        #expect(defaults.data(forKey: "profile.extras.42") == nil)
        service.load(user: user(84))
        #expect(service.snapshot.achievements == nil)
        try await waitForLoad(service)
        #expect(service.snapshot.organizations?.organizations.first?.login == "user-84-org")
    }

    @Test("重启后尚未打开浮层也能清除旧快照")
    func resetClearsUnloadedDiskCache() {
        let defaults = makeDefaults()
        defaults.set(Data("cached memberships".utf8), forKey: "profile.extras.42")
        let service = ProfileExtrasService(api: ProfileExtrasMock(), defaults: defaults)
        service.reset()
        #expect(defaults.data(forKey: "profile.extras.42") == nil)
    }
}

/// actor 可在并行分区请求中安全计数；返回内容包含账号身份以捕获跨账号缓存混用。
private actor ProfileExtrasMock: GitHubProfileExtrasProviding {
    private var failAchievements = false
    private var empty = false
    private(set) var calls = 0

    func configure(failAchievements: Bool, empty: Bool) {
        self.failAchievements = failAchievements
        self.empty = empty
    }

    func getProfileAchievements(login: String, forceRefresh: Bool) async throws -> [GitHubAchievement] {
        calls += 1
        if failAchievements { throw URLError(.notConnectedToInternet) }
        return empty ? [] : [GitHubAchievement(
            id: "yolo", name: "YOLO",
            imageURL: URL(string: "https://github.githubassets.com/assets/yolo.png")!, tier: nil
        )]
    }

    func getProfileOrganizations(login: String, forceRefresh: Bool) async throws -> GitHubProfileOrganizations {
        calls += 1
        return GitHubProfileOrganizations(
            organizations: empty ? [] : [
                GitHubOrganizationDTO(id: 101, login: "\(login)-org", avatarUrl: nil, description: nil)
            ],
            accessLimited: false
        )
    }

    func getProfileSponsors() async throws -> GitHubSponsors {
        calls += 1
        return GitHubSponsors(
            hasSponsorsListing: !empty,
            sponsors: empty ? [] : [GitHubSponsor(id: "sponsor", login: "sponsor", avatarUrl: nil)],
            sponsoring: []
        )
    }
}
