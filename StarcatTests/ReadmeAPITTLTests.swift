//
//  ReadmeAPITTLTests.swift
//  StarcatTests
//
//  ReadmeAPI 的软过期短路（softTtl）纯逻辑单测。
//
//  本测试仅覆盖 `ReadmeAPI.isWithinSoftTtl(cachedAt:now:softTtl:)` 静态函数，
//  这是 Phase 1 引入的"6h 内不发条件请求"短路的核心判定。
//
//  为什么不测完整的 `fetchHTML` 路径：
//  - `ReadmeAPI` 依赖具体的 `GitHubAPIClient`（actor，无协议抽象）
//  - 完整网络路径单测要等 D-14（URLProtocol stub）落地后一起做
//  - 把判定逻辑提取为静态函数后，逻辑分支可独立验证
//
//  `sessionNotFound` 行为（`ReadmeViewModel` 层的 Set<Int64>）也未在此覆盖：
//  - 需要 @MainActor + @Observable 测试基础设施
//  - 行为由"切换 repo 后 Console 日志数"手动验证（详见 docs Phase 1 T1.10）
//

import Testing
import Foundation
@testable import Starcat

@Suite("ReadmeAPI softTtl 短路")
struct ReadmeAPITTLTests {

    /// 固定基准时间，避免依赖系统时钟波动。
    private let now = Date(timeIntervalSince1970: 1_780_000_000) // 约 2026-06-30 17:46 UTC

    @Test("cached_at 在 softTtl 内 → 命中短路")
    func withinSoftTtl() {
        let cachedAt = ISO8601DateFormatter.shared.string(
            from: now.addingTimeInterval(-3600) // 1h 前
        )
        #expect(
            ReadmeAPI.isWithinSoftTtl(cachedAt: cachedAt, now: now, softTtl: 6 * 3600) == true
        )
    }

    @Test("cached_at 超出 softTtl → 不短路（须走网络）")
    func expiredSoftTtl() {
        let cachedAt = ISO8601DateFormatter.shared.string(
            from: now.addingTimeInterval(-7 * 3600) // 7h 前
        )
        #expect(
            ReadmeAPI.isWithinSoftTtl(cachedAt: cachedAt, now: now, softTtl: 6 * 3600) == false
        )
    }

    @Test("cached_at 恰好等于 softTtl → 不短路（半开区间 `<`，保守走网络）")
    func exactlyAtBoundary() {
        let cachedAt = ISO8601DateFormatter.shared.string(
            from: now.addingTimeInterval(-6 * 3600)
        )
        #expect(
            ReadmeAPI.isWithinSoftTtl(cachedAt: cachedAt, now: now, softTtl: 6 * 3600) == false
        )
    }

    @Test("无效 ISO8601 字符串 → 不短路（脏数据保守失效）")
    func invalidCachedAt() {
        #expect(
            ReadmeAPI.isWithinSoftTtl(cachedAt: "not-iso-8601", now: now, softTtl: 6 * 3600) == false
        )
        #expect(
            ReadmeAPI.isWithinSoftTtl(cachedAt: "", now: now, softTtl: 6 * 3600) == false
        )
    }

    @Test("cached_at 在未来（时钟漂移）→ 命中（不打扰 GitHub）")
    func clockDrift() {
        let cachedAt = ISO8601DateFormatter.shared.string(
            from: now.addingTimeInterval(3600) // 1h 后
        )
        // now.timeIntervalSince(future) 为负数，仍 < softTtl → true
        #expect(
            ReadmeAPI.isWithinSoftTtl(cachedAt: cachedAt, now: now, softTtl: 6 * 3600) == true
        )
    }
}
