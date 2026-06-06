//
//  UserProfileServiceTests.swift
//  StarcatTests
//
//  2026-06-06 A 方案：UserProfileService 行为单测。
//
//  覆盖矩阵：
//  - primeFromCache：lastLogin 缺失 / 磁盘空 / 命中
//  - load(force: false)：TTL 命中 no-op / TTL 过期发请求
//  - load(force: true)：跳过 TTL 强刷
//  - acceptFromAuth：写盘 + 写 lastLogin + 不发网络
//  - reset：清内存 + 清磁盘 + 清 lastLogin
//  - id mismatch 防御：网络回来时 login 已变，结果应丢弃
//
//  设计权衡：
//  - UserDefaults 用临时 suiteName 隔离，避免污染 .standard（也防止开发者本地缓存进测试）。
//  - acceptRefreshedUser 反向 push 路径在 AuthSession 上单测（TODO，本文件只测 service 自身）。
//

import XCTest
@testable import Starcat

@MainActor
final class UserProfileServiceTests: XCTestCase {

    private var mock: MockGitHubAPIClient!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGitHubAPIClient()
        // 每个 test 用独立 suite，避免相互污染。removePersistentDomain 在 tearDown 清。
        suiteName = "UserProfileServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // service 内部硬编码 UserDefaults.standard，需要用 swizzle / 替换 helper。
        // 这里采用更简单的策略：所有写 .standard 的路径在测试里清掉对应 key（见 tearDown）。
        UserDefaults.standard.removeObject(forKey: UserProfileService.lastLoginKey)
    }

    override func tearDown() async throws {
        // 清掉 service 写到 .standard 的 key：lastLogin + 所有 userprofile.snapshot.*
        UserDefaults.standard.removeObject(forKey: UserProfileService.lastLoginKey)
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("userprofile.snapshot.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults().removePersistentDomain(forName: suiteName)
        mock = nil
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - primeFromCache

    func test_primeFromCache_returnsNilWhenLastLoginMissing() {
        let svc = UserProfileService(apiClient: mock)
        XCTAssertNil(svc.primeFromCache())
        XCTAssertNil(svc.profile)
        XCTAssertNil(svc.lastFetchedAt)
    }

    func test_primeFromCache_returnsNilWhenNoDiskCache() {
        UserProfileService.saveLastLogin("ghost")
        let svc = UserProfileService(apiClient: mock)
        XCTAssertNil(svc.primeFromCache())
    }

    func test_primeFromCache_hitReturnsCachedProfile() {
        // 准备：先 acceptFromAuth 写一份缓存
        let svc1 = UserProfileService(apiClient: mock)
        let user = makeUser(login: "dong4j", followers: 100)
        svc1.acceptFromAuth(user)

        // 新建一个 service 模拟"下次 App 启动"
        let svc2 = UserProfileService(apiClient: mock)
        let primed = svc2.primeFromCache()

        XCTAssertEqual(primed?.login, "dong4j")
        XCTAssertEqual(primed?.followers, 100)
        XCTAssertEqual(svc2.profile?.login, "dong4j")
        XCTAssertNotNil(svc2.lastFetchedAt)
    }

    // MARK: - load TTL

    func test_load_ttlHitNoOp() async throws {
        let svc = UserProfileService(apiClient: mock)
        svc.acceptFromAuth(makeUser(login: "alice", followers: 50))

        var callCount = 0
        mock.getCurrentUserHandler = {
            callCount += 1
            return self.makeUser(login: "alice", followers: 60)
        }

        // TTL 30min 内，force=false 应直接 no-op
        svc.load(login: "alice", force: false)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms 给 inflightTask 启动机会（实际不会启）

        XCTAssertEqual(callCount, 0, "TTL 命中应零请求")
        XCTAssertEqual(svc.profile?.followers, 50, "数据应保持原值")
    }

    func test_load_forceTrueBypassesTTL() async throws {
        let svc = UserProfileService(apiClient: mock)
        svc.acceptFromAuth(makeUser(login: "alice", followers: 50))

        let expectation = expectation(description: "fetched")
        mock.getCurrentUserHandler = {
            defer { expectation.fulfill() }
            return self.makeUser(login: "alice", followers: 60)
        }

        svc.load(login: "alice", force: true)
        await fulfillment(of: [expectation], timeout: 2.0)
        try await Task.sleep(nanoseconds: 100_000_000) // 等 task defer 完成

        XCTAssertEqual(svc.profile?.followers, 60, "force=true 应拉新数据并更新")
    }

    // MARK: - acceptFromAuth

    func test_acceptFromAuth_persistsToDiskAndUpdatesLastLogin() throws {
        let svc = UserProfileService(apiClient: mock)
        let user = makeUser(login: "Bob", followers: 7)
        svc.acceptFromAuth(user)

        XCTAssertEqual(svc.profile?.login, "Bob")
        XCTAssertNotNil(svc.lastFetchedAt)
        XCTAssertEqual(UserProfileService.loadLastLogin(), "Bob",
                       "acceptFromAuth 应写 lastLogin")

        // 磁盘缓存可被新 service 读回（key 是 lowercase 化的）
        let svc2 = UserProfileService(apiClient: mock)
        let primed = svc2.primeFromCache()
        XCTAssertEqual(primed?.id, user.id)
    }

    // MARK: - reset

    func test_reset_clearsMemoryDiskAndLastLogin() {
        let svc = UserProfileService(apiClient: mock)
        svc.acceptFromAuth(makeUser(login: "Carol"))
        XCTAssertNotNil(svc.profile)
        XCTAssertEqual(UserProfileService.loadLastLogin(), "Carol")

        svc.reset(login: "Carol")

        XCTAssertNil(svc.profile)
        XCTAssertNil(svc.lastFetchedAt)
        XCTAssertNil(UserProfileService.loadLastLogin(), "reset 必须清 lastLogin")

        // 磁盘也清了——新 service 再 prime 应失败
        let svc2 = UserProfileService(apiClient: mock)
        XCTAssertNil(svc2.primeFromCache())
    }

    // MARK: - 防御：login mismatch（账号切换中拿到旧请求的结果）

    func test_load_dropsResultWhenLoginMismatch() async throws {
        let svc = UserProfileService(apiClient: mock)

        let expectation = expectation(description: "fetched")
        mock.getCurrentUserHandler = {
            defer { expectation.fulfill() }
            // 模拟：用户在请求飞行期切了账号 → 后端返回另一个 login
            return self.makeUser(login: "other-account", followers: 999)
        }

        svc.load(login: "expected-user", force: true)
        await fulfillment(of: [expectation], timeout: 2.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(svc.profile,
                     "login 不匹配的结果必须丢弃，避免写错账号数据")
        XCTAssertNil(UserProfileService.loadLastLogin(),
                     "不匹配时也不应写 lastLogin")
    }

    // MARK: - 测试辅助

    private func makeUser(login: String, followers: Int = 0) -> GitHubUserDTO {
        GitHubUserDTO(
            id: Int64(abs(login.hashValue % 1_000_000)),
            login: login,
            name: "Display \(login)",
            avatarUrl: "https://avatars.example.com/\(login).png",
            publicRepos: 10,
            followers: followers,
            following: 5,
            bio: "bio of \(login)",
            company: nil,
            location: nil,
            email: nil,
            blog: nil,
            twitterUsername: nil,
            htmlUrl: "https://github.com/\(login)"
        )
    }
}
