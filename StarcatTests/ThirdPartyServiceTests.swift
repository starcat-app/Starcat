//
//  ThirdPartyServiceTests.swift
//  StarcatTests
//
//  覆盖 R-03.1（2026-06-11）URL 规范化与 service-aware 归一化：
//   - `ThirdPartyService.validate(_:)` 的通用规范化（trim 末尾 `/`）
//   - `ThirdPartyService.normalizedBaseURL(_:)` 的服务感知归一化（sharing 剥末尾 `/api`）
//
//  对应实现：`Starcat/Core/Settings/ThirdPartyService.swift`
//
//  设计动机回顾（dong4j 2026-06-11 反馈）：
//   - "sharing-api 还是 404" → sharing 的设计假设 baseURL 含 `/api`，本地 :5001 不含，
//     业务 path 拼出来少一段 → 全 404；现在统一改成 baseURL 不含 `/api`，paths 写绝对
//   - "http://127.0.0.1:5004 和 http://127.0.0.1:5004/ 都应该正常，starcat 处理成无尾斜杠"
//     → validate 阶段 URLComponents 重组、剥末尾 `/`
//

import Testing
import Foundation
@testable import Starcat

@Suite("ThirdPartyService")
struct ThirdPartyServiceTests {

    // MARK: - validate 通用规范化

    @Test("validate: 空字符串 → .empty")
    func validateEmptyReturnsEmpty() {
        #expect(ThirdPartyService.validate("") == .empty)
        #expect(ThirdPartyService.validate("   ") == .empty)
        #expect(ThirdPartyService.validate("\n\t") == .empty)
    }

    @Test("validate: 末尾单个 `/` 被剥掉")
    func validateStripsSingleTrailingSlash() {
        let result = ThirdPartyService.validate("http://127.0.0.1:5004/")
        guard case .valid(let url) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(url.absoluteString == "http://127.0.0.1:5004",
                "trailing slash should be stripped, got \(url.absoluteString)")
    }

    @Test("validate: 无尾斜杠的输入保持原样")
    func validatePreservesNoTrailingSlash() {
        let result = ThirdPartyService.validate("http://127.0.0.1:5004")
        guard case .valid(let url) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(url.absoluteString == "http://127.0.0.1:5004")
    }

    @Test("validate: 多重末尾 `/` 全剥（防御）")
    func validateStripsMultipleTrailingSlashes() {
        let result = ThirdPartyService.validate("http://127.0.0.1:5004///")
        guard case .valid(let url) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(url.absoluteString == "http://127.0.0.1:5004",
                "all trailing slashes should be stripped, got \(url.absoluteString)")
    }

    @Test("validate: 带路径的 URL，末尾 `/` 被剥但路径保留")
    func validateStripsTrailingSlashWithPath() {
        let result = ThirdPartyService.validate("https://api.example.com/v1/")
        guard case .valid(let url) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(url.absoluteString == "https://api.example.com/v1",
                "trailing slash after path should be stripped, got \(url.absoluteString)")
    }

    @Test("validate: 首尾空白被剥再走规范化")
    func validateTrimsWhitespaceFirst() {
        let result = ThirdPartyService.validate("  http://127.0.0.1:5004/  ")
        guard case .valid(let url) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(url.absoluteString == "http://127.0.0.1:5004")
    }

    @Test("validate: 非法 scheme → .invalid")
    func validateRejectsBadScheme() {
        let result = ThirdPartyService.validate("file:///tmp/x")
        guard case .invalid = result else {
            Issue.record("Expected .invalid, got \(result)")
            return
        }
    }

    @Test("validate: 缺 host → .invalid")
    func validateRejectsMissingHost() {
        let result = ThirdPartyService.validate("http:///path-only")
        guard case .invalid = result else {
            Issue.record("Expected .invalid, got \(result)")
            return
        }
    }

    // MARK: - normalizedBaseURL（service-aware）

    @Test("normalizedBaseURL: 非 sharing 服务，末尾 `/` 被剥")
    func normalizedTrimsTrailingSlashForAllServices() {
        let input = URL(string: "http://127.0.0.1:5004/")!
        for service in ThirdPartyService.allCases {
            let normalized = service.normalizedBaseURL(input)
            #expect(normalized.absoluteString == "http://127.0.0.1:5004",
                    "service=\(service.rawValue) should strip trailing /, got \(normalized.absoluteString)")
        }
    }

    @Test("normalizedBaseURL: sharing 末尾 `/api` 被剥（兼容 R-03 历史持久化）")
    func normalizedStripsApiSuffixForSharing() {
        let input = URL(string: "https://starcat-sharing-api.fly.dev/api")!
        let normalized = ThirdPartyService.sharing.normalizedBaseURL(input)
        #expect(normalized.absoluteString == "https://starcat-sharing-api.fly.dev",
                "sharing should strip /api suffix, got \(normalized.absoluteString)")
    }

    @Test("normalizedBaseURL: sharing 末尾 `/api/` 也剥（先剥 / 再剥 /api）")
    func normalizedStripsApiSlashSuffixForSharing() {
        let input = URL(string: "https://share.local/api/")!
        let normalized = ThirdPartyService.sharing.normalizedBaseURL(input)
        #expect(normalized.absoluteString == "https://share.local",
                "sharing should strip both trailing / and /api, got \(normalized.absoluteString)")
    }

    @Test("normalizedBaseURL: 非 sharing 服务，末尾 `/api` 保留（路径是合法 base 段，不该误剥）")
    func normalizedKeepsApiSuffixForNonSharing() {
        let input = URL(string: "https://my-trending.example.com/api")!
        for service in [ThirdPartyService.trending, .weekly, .wiki] {
            let normalized = service.normalizedBaseURL(input)
            #expect(normalized.absoluteString == "https://my-trending.example.com/api",
                    "service=\(service.rawValue) should keep /api suffix, got \(normalized.absoluteString)")
        }
    }

    @Test("normalizedBaseURL: sharing 仅含 `/api` 单段（无 host 之外其它路径）也能剥")
    func normalizedHandlesSharingPureApiPath() {
        let input = URL(string: "https://share.local/api")!
        let normalized = ThirdPartyService.sharing.normalizedBaseURL(input)
        #expect(normalized.absoluteString == "https://share.local")
    }

    @Test("normalizedBaseURL: 已是规范形态的 URL 不变")
    func normalizedIsIdempotent() {
        let already = URL(string: "https://share.local")!
        for service in ThirdPartyService.allCases {
            let normalized = service.normalizedBaseURL(already)
            #expect(normalized == already,
                    "service=\(service.rawValue) should be idempotent on already-normalized URL")
        }
    }

    // MARK: - pingURL 端到端

    @Test("pingURL: 4 个服务统一命中 /api/v1/ping，无论 baseURL 末尾形态")
    func pingURLUnifiedPathRegardlessOfBaseShape() {
        let inputs = [
            URL(string: "http://127.0.0.1:5004")!,
            URL(string: "http://127.0.0.1:5004/")!,
            URL(string: "http://127.0.0.1:5004///")!,
        ]
        for service in ThirdPartyService.allCases {
            for input in inputs {
                let url = service.pingURL(base: input)
                #expect(url.path == "/api/v1/ping",
                        "service=\(service.rawValue) base=\(input.absoluteString) → path=\(url.path), expected /api/v1/ping")
            }
        }
    }

    @Test("pingURL: sharing 历史 baseURL `*/api` 也能正确命中 /api/v1/ping")
    func pingURLForLegacySharingApiSuffix() {
        let inputs = [
            URL(string: "https://share.local/api")!,
            URL(string: "https://share.local/api/")!,
        ]
        for input in inputs {
            let url = ThirdPartyService.sharing.pingURL(base: input)
            #expect(url.path == "/api/v1/ping",
                    "sharing base=\(input.absoluteString) → path=\(url.path), expected /api/v1/ping")
        }
    }

    // MARK: - healthURL

    @Test("healthURL: 4 个服务统一命中 /healthz")
    func healthURLUnifiedPath() {
        for service in ThirdPartyService.allCases {
            let url = service.healthURL(base: URL(string: "https://api.local")!)
            #expect(url.path == "/healthz",
                    "service=\(service.rawValue) should hit /healthz, got \(url.path)")
        }
    }

    @Test("healthURL: sharing 历史 baseURL `*/api` 也能正确命中 /healthz")
    func healthURLForLegacySharingApiSuffix() {
        let url = ThirdPartyService.sharing.healthURL(base: URL(string: "https://share.local/api")!)
        #expect(url.path == "/healthz")
    }
}
