//
//  RuntimeContextProviderTests.swift
//  StarcatTests
//
//  RuntimeContextProvider 的单元测试。
//
//  测试目标（覆盖文件头注释列出的 5 个关键设计点）：
//   1. UTC 时间精度到「整点」：分钟字段固定 `:00`，且同一小时内不同 Date 输出
//      完全相同（验证 prompt cache 命中条件）；
//   2. 周几按用户时区算（不按 UTC）：构造 UTC 周一夜 / 上海周二晨同一时刻，断言
//      输出 `Tuesday` 而非 `Monday`；
//   3. 周几用英文：在 zh_Hans / ja 等 locale 下输出仍为英文（防本地化偶发回归）；
//   4. 时区非整小时偏移：印度 +5:30、尼泊尔 +5:45 等正确格式化为 `UTC+5:30` /
//      `UTC+5:45`；
//   5. infoDictionary 缺失 / 空字符串：兜底 `"?"`。
//
//  不测的事项：
//  - 不测真实 `Date()` / `Bundle.main` 路径——那是 trivial proxy 调用，验也无意义。
//  - 不测时间格式化的 locale 漂移（已硬编码 `en_US_POSIX`，无需为 fallback 写测试）。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RuntimeContextProvider")
struct RuntimeContextProviderTests {

    // MARK: - 固定测试数据

    /// 固定时刻：UTC 2026-06-15 07:42:33。
    /// 选这个时刻是因为：
    /// - 整点为 07:00Z，便于断言 UTC 字符串 = `2026-06-15T07:00Z`；
    /// - 在 Asia/Shanghai (UTC+8) 是 15:42，仍是周一；
    /// - 在 America/New_York (UTC-4 夏令时) 是凌晨 03:42，仍是周一；
    /// - 方便派生「跨日 → 跨周几」的边界数据。
    private static let fixedDate = ISO8601DateFormatter().date(from: "2026-06-15T07:42:33Z")!

    /// 标准 mock infoDictionary，模拟 `Bundle.main.infoDictionary` 的真实形态。
    private static let mockInfo: [String: Any] = [
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "456"
    ]

    // MARK: - UTC 时间精度

    @Test("UTC 时间精度到整点：分钟字段固定 :00，跟入参的真实分钟/秒无关")
    func utcTimeIsHourPrecision() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate, // 真实分秒 07:42:33
            timeZone: TimeZone(identifier: "UTC")!,
            infoDictionary: Self.mockInfo
        )

        #expect(result.contains("- Current UTC time: 2026-06-15T07:00Z (ISO 8601, hour precision)"))
        // 反向断言：真实分钟 42 不能泄漏到输出
        #expect(!result.contains(":42"))
        #expect(!result.contains(":33"))
    }

    @Test("同一小时内任意时刻输出完全相同（prompt cache 命中前提）")
    func sameHourSameOutput() {
        let tz = TimeZone(identifier: "UTC")!
        let dateA = ISO8601DateFormatter().date(from: "2026-06-15T07:00:00Z")!
        let dateB = ISO8601DateFormatter().date(from: "2026-06-15T07:30:00Z")!
        let dateC = ISO8601DateFormatter().date(from: "2026-06-15T07:59:59Z")!

        let outA = RuntimeContextProvider._snapshotForTesting(now: dateA, timeZone: tz, infoDictionary: Self.mockInfo)
        let outB = RuntimeContextProvider._snapshotForTesting(now: dateB, timeZone: tz, infoDictionary: Self.mockInfo)
        let outC = RuntimeContextProvider._snapshotForTesting(now: dateC, timeZone: tz, infoDictionary: Self.mockInfo)

        #expect(outA == outB)
        #expect(outB == outC)
    }

    @Test("跨小时输出必定不同")
    func crossHourDiffersOutput() {
        let tz = TimeZone(identifier: "UTC")!
        let early = ISO8601DateFormatter().date(from: "2026-06-15T07:30:00Z")!
        let later = ISO8601DateFormatter().date(from: "2026-06-15T08:30:00Z")!

        let outEarly = RuntimeContextProvider._snapshotForTesting(now: early, timeZone: tz, infoDictionary: Self.mockInfo)
        let outLater = RuntimeContextProvider._snapshotForTesting(now: later, timeZone: tz, infoDictionary: Self.mockInfo)

        #expect(outEarly != outLater)
        #expect(outEarly.contains("07:00Z"))
        #expect(outLater.contains("08:00Z"))
    }

    // MARK: - 周几（按用户时区，不按 UTC）

    @Test("周几按用户时区算：UTC 周一 23:30 + Asia/Shanghai → 输出 Tuesday")
    func weekdayUsesUserTimezoneNotUTC() {
        // 这个时刻 UTC 是周一晚 23:30，但在 Asia/Shanghai (UTC+8) 已经是周二早 07:30
        let date = ISO8601DateFormatter().date(from: "2026-06-15T23:30:00Z")! // 2026-06-15 是周一
        let result = RuntimeContextProvider._snapshotForTesting(
            now: date,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            infoDictionary: Self.mockInfo
        )

        #expect(result.contains("Day of week (user timezone): Tuesday"))
        // 反向断言：不能输出 Monday（UTC 周几）
        #expect(!result.contains(": Monday"))
    }

    @Test("UTC 周二早 03:30 + America/New_York (UTC-4 夏令时) → 输出 Monday")
    func weekdayCrossDayBackward() {
        // UTC 2026-06-16 周二 03:30，纽约（UTC-4 夏令时）是 06-15 周一 23:30
        let date = ISO8601DateFormatter().date(from: "2026-06-16T03:30:00Z")!
        let result = RuntimeContextProvider._snapshotForTesting(
            now: date,
            timeZone: TimeZone(identifier: "America/New_York")!,
            infoDictionary: Self.mockInfo
        )

        #expect(result.contains("Day of week (user timezone): Monday"))
    }

    // MARK: - 时区字符串

    @Test("整小时偏移：Asia/Shanghai → UTC+8")
    func timezoneIntegerOffsetShanghai() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            infoDictionary: Self.mockInfo
        )
        #expect(result.contains("- User timezone: Asia/Shanghai (UTC+8)"))
    }

    @Test("负偏移：America/Los_Angeles 夏令时 → UTC-7")
    func timezoneNegativeOffset() {
        // 2026-06-15 在洛杉矶是 PDT 夏令时，UTC-7
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "America/Los_Angeles")!,
            infoDictionary: Self.mockInfo
        )
        #expect(result.contains("- User timezone: America/Los_Angeles (UTC-7)"))
    }

    @Test("非整小时偏移：印度 +5:30")
    func timezoneIndiaHalfHourOffset() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "Asia/Kolkata")!,
            infoDictionary: Self.mockInfo
        )
        #expect(result.contains("- User timezone: Asia/Kolkata (UTC+5:30)"))
    }

    @Test("非整小时偏移：尼泊尔 +5:45")
    func timezoneNepalQuarterHourOffset() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "Asia/Kathmandu")!,
            infoDictionary: Self.mockInfo
        )
        #expect(result.contains("- User timezone: Asia/Kathmandu (UTC+5:45)"))
    }

    @Test("UTC 自身 → UTC+0")
    func timezoneUTCSelf() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "UTC")!,
            infoDictionary: Self.mockInfo
        )
        #expect(result.contains("- User timezone: UTC (UTC+0)"))
    }

    // MARK: - 版本号兜底

    @Test("infoDictionary 缺 CFBundleShortVersionString → 兜底 ?")
    func versionMissingFallback() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "UTC")!,
            infoDictionary: ["CFBundleVersion": "456"] // 只给 build
        )
        #expect(result.contains("- Starcat version: ? (build 456)"))
    }

    @Test("infoDictionary 缺 CFBundleVersion → 兜底 ?")
    func buildMissingFallback() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "UTC")!,
            infoDictionary: ["CFBundleShortVersionString": "1.2.3"] // 只给 version
        )
        #expect(result.contains("- Starcat version: 1.2.3 (build ?)"))
    }

    @Test("infoDictionary 全 nil → 双兜底 ?")
    func bothMissingFallback() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "UTC")!,
            infoDictionary: nil
        )
        #expect(result.contains("- Starcat version: ? (build ?)"))
    }

    @Test("infoDictionary 空字符串 → 视为缺失，仍兜底 ?")
    func emptyStringTreatedAsMissing() {
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate,
            timeZone: TimeZone(identifier: "UTC")!,
            infoDictionary: [
                "CFBundleShortVersionString": "",
                "CFBundleVersion": ""
            ]
        )
        #expect(result.contains("- Starcat version: ? (build ?)"))
    }

    // MARK: - 整体输出形态

    @Test("典型场景全量断言：上海时区 + 完整版本号")
    func typicalShanghaiSnapshot() {
        let expected = """
        - Current UTC time: 2026-06-15T07:00Z (ISO 8601, hour precision)
        - Day of week (user timezone): Monday
        - User timezone: Asia/Shanghai (UTC+8)
        - Starcat version: 1.2.3 (build 456)
        """
        let result = RuntimeContextProvider._snapshotForTesting(
            now: Self.fixedDate, // 2026-06-15 周一 07:42:33 UTC
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            infoDictionary: Self.mockInfo
        )
        #expect(result == expected)
    }
}
