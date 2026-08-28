//
//  RepoAIGenerationOptionsTests.swift
//  StarcatTests
//
//  单仓 AI 摘要「本次生成」开关：从全局设置拷贝，用户改完不得写回。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AI 摘要本次生成选项")
@MainActor
struct RepoAIGenerationOptionsTests {

    @Test("打开面板时从全局设置拷贝，切换本次开关不写回")
    func perRunOverridesDoNotPersistSettings() throws {
        let fixture = try makeFixture()
        fixture.settings.aiRepoContextEnabled = true
        fixture.settings.externalContextEnabled = true

        var repo = Repo.makeMinimal(owner: "acme", name: "demo")
        repo.id = 7
        let viewModel = fixture.store.viewModel(for: repo.id)
        viewModel.syncGenerationOptions(for: repo)

        #expect(viewModel.includeCodeContextForNextGeneration)
        #expect(viewModel.includeExternalSearchForNextGeneration)

        viewModel.includeCodeContextForNextGeneration = false
        viewModel.includeExternalSearchForNextGeneration = false

        #expect(fixture.settings.aiRepoContextEnabled)
        #expect(fixture.settings.externalContextEnabled)
    }

    @Test("私有仓库在未允许私仓外搜时，本次默认也保持关闭")
    func privateRepoSeedsExternalSearchOff() throws {
        let fixture = try makeFixture()
        fixture.settings.externalContextEnabled = true
        fixture.settings.externalSearchAllowPrivateRepos = false

        var repo = Repo.makeMinimal(owner: "acme", name: "secret")
        repo.id = 8
        repo.isPrivate = true
        let viewModel = fixture.store.viewModel(for: repo.id)
        viewModel.syncGenerationOptions(for: repo)

        #expect(!viewModel.includeExternalSearchForNextGeneration)
        #expect(
            !ExternalSearchContextProvider.allowsExternalContext(
                repoIsPrivate: true,
                enabled: true,
                allowPrivate: false
            )
        )
    }

    @Test("本次覆盖可以在全局关闭时仍允许公开仓外搜")
    func overrideCanEnableExternalSearchWhenGlobalOff() {
        #expect(
            ExternalSearchContextProvider.allowsExternalContext(
                repoIsPrivate: false,
                enabled: true,
                allowPrivate: false
            )
        )
        #expect(
            !ExternalSearchContextProvider.allowsExternalContext(
                repoIsPrivate: false,
                enabled: false,
                allowPrivate: false
            )
        )
    }

    private struct Fixture {
        let store: RepoAIInsightSessionStore
        let settings: AppSettings
    }

    private func makeFixture() throws -> Fixture {
        let database = try InMemoryDatabaseManager()
        let suiteName = "test.starcat.repo-ai-generation-options.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = RepoAIInsightService(
            summaryRepository: GRDBAISummaryRepository(database: database),
            readmeRepository: ReadmeRepository(database: database),
            settings: settings,
            keychain: keychain
        )
        let store = RepoAIInsightSessionStore(
            service: service,
            tagRepository: GRDBTagRepository(database: database),
            repoTagRepository: GRDBRepoTagRepository(database: database)
        )
        return Fixture(store: store, settings: settings)
    }
}
