//
//  ExternalSearchContextProviderTests.swift
//  StarcatTests
//
//  覆盖 AI External Context 的 Provider 选择、私有仓库边界与聚合搜索 gate。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ExternalSearchContextProvider")
@MainActor
struct ExternalSearchContextProviderTests {
    @Test("Automatic 按 Exa -> Tavily -> Brave -> AnySearch 选择首个可用 Provider")
    func automaticUsesPriorityOrder() async throws {
        let settings = makeSettings()
        for provider in ExternalSearchProviderID.allCases {
            enable(provider, settings: settings)
        }
        settings.externalContextProviderSelection = .automatic
        let recorder = ProviderCallRecorder()
        let contextProvider = ExternalSearchContextProvider(
            settings: settings,
            diskCache: nil,
            providerFactory: { providerID in StubExternalSearchProvider(providerID: providerID, recorder: recorder) }
        )

        let context = try await contextProvider.collect(for: makeRepo())

        #expect(context?.markdown.contains(#"source="Exa""#) == true)
        #expect(Set(recorder.providerIDs) == Set([.exa]))
        #expect(context?.sourceItems.first?.provider == .exa)
        #expect(context?.sourceItems.first?.host == "example.com")
    }

    @Test("Agent 结构化查询完整传入现有 Provider")
    func directRequestPreservesModelFilters() async throws {
        let settings = makeSettings()
        enable(.tavily, settings: settings)
        settings.externalContextProviderSelection = .tavily
        let recorder = ProviderCallRecorder()
        let contextProvider = ExternalSearchContextProvider(
            settings: settings,
            diskCache: nil,
            providerFactory: { providerID in StubExternalSearchProvider(providerID: providerID, recorder: recorder) }
        )
        let request = ExternalSearchRequest(
            query: "Swift agent tool calling",
            purpose: .aiContext,
            maxResults: 7,
            freshness: "week",
            includeDomains: ["github.com", "swift.org"]
        )

        let context = try await contextProvider.collect(request: request, cacheScopeID: 42)

        #expect(recorder.requests == [request])
        #expect(context?.sourceItems.count == 1)
        #expect(context?.sourceItems.first?.provider == .tavily)
    }

    @Test("私有仓库只发送 fullName，不发送 description")
    func privateRepoQueriesOnlyUseFullName() async throws {
        let settings = makeSettings()
        enable(.exa, settings: settings)
        settings.externalContextProviderSelection = .exa
        settings.externalSearchAllowPrivateRepos = true
        let recorder = ProviderCallRecorder()
        let contextProvider = ExternalSearchContextProvider(
            settings: settings,
            diskCache: nil,
            providerFactory: { providerID in StubExternalSearchProvider(providerID: providerID, recorder: recorder) }
        )

        _ = try await contextProvider.collect(for: makeRepo(isPrivate: true, description: "secret description"))

        #expect(recorder.queries.allSatisfy { $0.contains("owner/private-repo") })
        #expect(recorder.queries.allSatisfy { !$0.contains("secret description") })
    }

    @Test("非 Pro 即使开启 aggregate 偏好也不发起聚合")
    func aggregatePreferenceDoesNotRunForNonPro() async throws {
        let settings = makeSettings()
        for provider in ExternalSearchProviderID.allCases {
            enable(provider, settings: settings)
        }
        settings.aggregateExternalContextSearchEnabled = true
        settings.updateProEntitlementMirror(isPro: false)
        let recorder = ProviderCallRecorder()
        let contextProvider = ExternalSearchContextProvider(
            settings: settings,
            diskCache: nil,
            providerFactory: { providerID in StubExternalSearchProvider(providerID: providerID, recorder: recorder) }
        )

        _ = try await contextProvider.collect(for: makeRepo())

        #expect(Set(recorder.providerIDs) == Set([.exa]))
    }

    @Test("Pro 聚合允许部分 Provider 失败并保留成功结果")
    func aggregateAllowsPartialSuccess() async throws {
        let settings = makeSettings()
        enable(.exa, settings: settings)
        enable(.tavily, settings: settings)
        settings.aggregateExternalContextSearchEnabled = true
        settings.updateProEntitlementMirror(isPro: true)
        let recorder = ProviderCallRecorder()
        let contextProvider = ExternalSearchContextProvider(
            settings: settings,
            diskCache: nil,
            providerFactory: { providerID in
                StubExternalSearchProvider(
                    providerID: providerID,
                    recorder: recorder,
                    error: providerID == .tavily ? TestExternalSearchError.failed : nil
                )
            }
        )

        let context = try await contextProvider.collect(for: makeRepo())

        #expect(context?.markdown.contains(#"source="Aggregate""#) == true)
        #expect(context?.markdown.contains("[Exa]") == true)
        #expect(Set(recorder.providerIDs) == Set([.exa, .tavily]))
    }

    @Test("External Context cache key 包含 query fingerprint")
    func queryFingerprintCacheMissesWhenRepoQueryChanges() async throws {
        let settings = makeSettings()
        enable(.exa, settings: settings)
        settings.externalContextProviderSelection = .exa
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ExternalSearchContextProviderTests.\(UUID().uuidString)", isDirectory: true)
        let cache = DiskExternalSearchCache(rootOverride: root)
        let recorder = ProviderCallRecorder()
        let contextProvider = ExternalSearchContextProvider(
            settings: settings,
            diskCache: cache,
            providerFactory: { providerID in StubExternalSearchProvider(providerID: providerID, recorder: recorder) }
        )

        _ = try await contextProvider.collect(for: makeRepo(description: "first description"))
        _ = try await contextProvider.collect(for: makeRepo(description: "first description"))
        _ = try await contextProvider.collect(for: makeRepo(description: "second description"))

        #expect(recorder.queries.count == 4)
    }

    @Test("聚合模式按 Provider 优先级去重并限制最多 8 条")
    func aggregateDeduplicatesAndBudgetsResults() async throws {
        let settings = makeSettings()
        for provider in ExternalSearchProviderID.allCases {
            enable(provider, settings: settings)
        }
        settings.aggregateExternalContextSearchEnabled = true
        settings.updateProEntitlementMirror(isPro: true)
        let recorder = ProviderCallRecorder()
        let contextProvider = ExternalSearchContextProvider(
            settings: settings,
            diskCache: nil,
            providerFactory: { providerID in
                StubExternalSearchProvider(
                    providerID: providerID,
                    recorder: recorder,
                    hits: Self.makeHits(for: providerID)
                )
            }
        )

        let context = try await contextProvider.collect(for: makeRepo())

        #expect(context?.sourceItems.count == 8)
        #expect(context?.sourceItems.first?.provider == .exa)
        #expect(context?.sourceItems.filter { $0.url.absoluteString == "https://example.com/duplicate" }.count == 1)
        #expect(context?.markdown.contains("preferred full text") == true)
    }

    private func makeSettings() -> AppSettings {
        let suite = "ExternalSearchContextProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        settings.externalContextEnabled = true
        settings.externalSearchAllowPrivateRepos = false
        settings.externalContextProviderSelection = .automatic
        return settings
    }

    private func enable(_ provider: ExternalSearchProviderID, settings: AppSettings) {
        settings.setExternalSearchAPIKey("key-\(provider.rawValue)", for: provider)
        settings.markExternalSearchCredentialVerified(for: provider)
        var providerSettings = settings.externalSearchSettings(for: provider)
        providerSettings.isEnabled = true
        settings.setExternalSearchSettings(providerSettings, for: provider)
    }

    private func makeRepo(
        isPrivate: Bool = false,
        description: String = "public description"
    ) -> Repo {
        Repo(
            id: isPrivate ? 2 : 1,
            owner: "owner",
            name: isPrivate ? "private-repo" : "public-repo",
            fullName: isPrivate ? "owner/private-repo" : "owner/public-repo",
            description: description,
            language: "Swift",
            starsCount: 1,
            forksCount: 1,
            watchersCount: 1,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/owner/repo",
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

    private nonisolated static func makeHits(for providerID: ExternalSearchProviderID) -> [ExternalSearchHit] {
        let uniqueCount = (providerID == .exa || providerID == .tavily) ? 2 : 4
        var hits: [ExternalSearchHit] = (0..<uniqueCount).map { index in
            ExternalSearchHit(
                title: "\(providerID.displayName) \(index)",
                url: URL(string: "https://example.com/\(providerID.rawValue)/\(index)")!,
                snippet: "snippet \(index)",
                extractedText: "text \(index)"
            )
        }
        hits.append(ExternalSearchHit(
            title: "Duplicate without text",
            url: URL(string: "https://example.com/duplicate")!,
            snippet: "duplicate snippet",
            extractedText: nil
        ))
        if providerID == .tavily {
            hits.append(ExternalSearchHit(
                title: "Duplicate with text",
                url: URL(string: "https://example.com/duplicate")!,
                snippet: "duplicate snippet",
                extractedText: "preferred full text"
            ))
        }
        return hits
    }
}

private final class ProviderCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [ExternalSearchProviderID] = []
    private var capturedQueries: [String] = []
    private var capturedRequests: [ExternalSearchRequest] = []

    var providerIDs: [ExternalSearchProviderID] { lock.withLock { providers } }
    var queries: [String] { lock.withLock { capturedQueries } }
    var requests: [ExternalSearchRequest] { lock.withLock { capturedRequests } }

    func record(providerID: ExternalSearchProviderID, request: ExternalSearchRequest) {
        lock.withLock {
            providers.append(providerID)
            capturedQueries.append(request.query)
            capturedRequests.append(request)
        }
    }
}

private struct StubExternalSearchProvider: ExternalSearchProvider {
    let providerID: ExternalSearchProviderID
    let recorder: ProviderCallRecorder
    var error: Error?
    var hits: [ExternalSearchHit]?

    var id: ExternalSearchProviderID { providerID }
    var capabilities: ExternalSearchCapabilities { .capabilities(for: providerID) }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        recorder.record(providerID: providerID, request: request)
        if let error { throw error }
        return ExternalSearchResponse(
            hits: hits ?? [
                ExternalSearchHit(
                    title: providerID.displayName,
                    url: URL(string: "https://example.com/\(providerID.rawValue)")!,
                    snippet: "snippet",
                    extractedText: "text"
                )
            ],
            metadata: ExternalSearchMetadata(provider: providerID, totalResults: 1)
        )
    }
}

private enum TestExternalSearchError: Error {
    case failed
}
