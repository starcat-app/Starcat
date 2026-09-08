//
//  AIProviderProfileModelMergeTests.swift
//  StarcatTests
//
//  覆盖 AI 设置页模型目录合并：去重、大目录默认不全开、容量截断。
//  这些规则直接防止「勾选模型时主线程 hang」。
//

import Testing
@testable import Starcat

@Suite("AIProviderProfile model merge")
struct AIProviderProfileModelMergeTests {

    @Test("小目录首次拉取：保留上游默认启用态且不去重丢失")
    func smallCatalogKeepsIncomingEnabledFlags() {
        let incoming = [
            AIModelDescriptor(providerID: "p", name: "MiniMax-M3", capability: .chat, isEnabled: true),
            AIModelDescriptor(providerID: "p", name: "MiniMax-M2.7", capability: .chat, isEnabled: true),
        ]

        let merged = AIProviderProfile.mergedDiscoveredModels(
            existing: [],
            incoming: incoming,
            providerID: "p"
        )

        #expect(merged.map(\.name) == ["MiniMax-M3", "MiniMax-M2.7"])
        #expect(merged.allSatisfy { $0.isEnabled })
    }

    @Test("重复 name 只保留第一条，避免 ForEach 重复 id")
    func deduplicatesByName() {
        let incoming = [
            AIModelDescriptor(providerID: "p", name: "dup", ownedBy: "first", capability: .chat),
            AIModelDescriptor(providerID: "p", name: "dup", ownedBy: "second", capability: .chat),
            AIModelDescriptor(providerID: "p", name: "other", capability: .chat),
        ]

        let merged = AIProviderProfile.mergedDiscoveredModels(
            existing: [],
            incoming: incoming,
            providerID: "p"
        )

        #expect(merged.map(\.name) == ["dup", "other"])
        #expect(merged.first?.ownedBy == "first")
    }

    @Test("大目录首次拉取：只自动启用有限个 Chat + 一个 Embedding")
    func largeCatalogFirstFetchEnablesLimitedSubset() {
        var incoming: [AIModelDescriptor] = (0..<60).map { index in
            AIModelDescriptor(
                providerID: "p",
                name: "chat-\(index)",
                capability: .chat,
                isEnabled: true
            )
        }
        incoming.append(
            AIModelDescriptor(
                providerID: "p",
                name: "embed-0",
                capability: .embedding,
                isEnabled: true
            )
        )

        let merged = AIProviderProfile.mergedDiscoveredModels(
            existing: [],
            incoming: incoming,
            providerID: "p"
        )

        let enabledChats = merged.filter { $0.isEnabled && $0.capability == .chat }
        let enabledEmbeddings = merged.filter { $0.isEnabled && $0.capability == .embedding }
        #expect(enabledChats.count == AIProviderProfile.firstFetchAutoEnableCount)
        #expect(enabledEmbeddings.count == 1)
        #expect(merged.filter(\.isEnabled).count == AIProviderProfile.firstFetchAutoEnableCount + 1)
    }

    @Test("再次拉取大目录：保留用户已启用，新增项默认关闭")
    func largeCatalogRefreshPreservesEnabledAndDisablesNew() {
        let existing = [
            AIModelDescriptor(providerID: "p", name: "keep-on", capability: .chat, isEnabled: true),
            AIModelDescriptor(providerID: "p", name: "keep-off", capability: .chat, isEnabled: false),
        ]
        var incoming: [AIModelDescriptor] = existing.map {
            AIModelDescriptor(
                providerID: "p",
                name: $0.name,
                capability: .chat,
                isEnabled: true
            )
        }
        for index in 0..<45 {
            incoming.append(
                AIModelDescriptor(
                    providerID: "p",
                    name: "new-\(index)",
                    capability: .chat,
                    isEnabled: true
                )
            )
        }

        let merged = AIProviderProfile.mergedDiscoveredModels(
            existing: existing,
            incoming: incoming,
            providerID: "p"
        )

        #expect(merged.first(where: { $0.name == "keep-on" })?.isEnabled == true)
        #expect(merged.first(where: { $0.name == "keep-off" })?.isEnabled == false)
        #expect(merged.filter { $0.name.hasPrefix("new-") }.allSatisfy { !$0.isEnabled })
    }

    @Test("超过容量上限时优先保留已启用模型")
    func truncatesPreferringEnabledModels() {
        let existing = [
            AIModelDescriptor(providerID: "p", name: "enabled-keep", capability: .tts, isEnabled: true)
        ]
        var incoming: [AIModelDescriptor] = [
            AIModelDescriptor(providerID: "p", name: "enabled-keep", capability: .tts, isEnabled: true)
        ]
        for index in 0..<(AIProviderProfile.maxStoredModels + 40) {
            incoming.append(
                AIModelDescriptor(
                    providerID: "p",
                    name: "bulk-\(index)",
                    capability: .chat,
                    isEnabled: true
                )
            )
        }

        let merged = AIProviderProfile.mergedDiscoveredModels(
            existing: existing,
            incoming: incoming,
            providerID: "p"
        )

        #expect(merged.count == AIProviderProfile.maxStoredModels)
        #expect(merged.contains(where: { $0.name == "enabled-keep" }))
    }

    @Test("sanitizedForStorage 去掉重复 name 并截断")
    func sanitizedForStorageDedupesAndCaps() {
        var models: [AIModelDescriptor] = [
            AIModelDescriptor(providerID: "p", name: "dup", capability: .chat),
            AIModelDescriptor(providerID: "p", name: "dup", capability: .chat),
        ]
        for index in 0..<(AIProviderProfile.maxStoredModels + 5) {
            models.append(
                AIModelDescriptor(providerID: "p", name: "m-\(index)", capability: .chat)
            )
        }
        let profile = AIProviderProfile(
            id: "p",
            provider: .openAICompatible,
            models: models
        )

        let sanitized = profile.sanitizedForStorage()
        #expect(sanitized.models.count == AIProviderProfile.maxStoredModels)
        #expect(sanitized.models.filter { $0.name == "dup" }.count == 1)
    }
}
