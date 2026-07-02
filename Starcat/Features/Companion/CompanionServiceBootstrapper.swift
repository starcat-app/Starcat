//
//  CompanionServiceBootstrapper.swift
//  Starcat
//
//  Browser Plugin 本机服务启动门控。
//
//  设计约束:
//  - 测试 host 必须先跳过, 避免为了读取 token 触发 Keychain 授权弹窗;
//  - 服务只由设置页中的 enabled 配置驱动, 避免 Debug 菜单和设置页双入口状态分裂;
//  - 持有 server 单例, 避免 NWListener 在启动函数返回后被释放。
//

import Foundation

@MainActor
enum CompanionServiceBootstrapper {
    private static var server: CompanionLocalServer?
    private static var dependencies: AppDependencies?

    /// App 启动期调用。用户在设置页启用 Browser Plugin Service 后, 下次启动自动恢复。
    static func startFromStoredConfiguration(dependencies: AppDependencies) {
        self.dependencies = dependencies
        guard !TestEnvironment.isRunning else { return }
        apply(configuration: .shared)
    }

    /// 设置页运行期调用。这里接收外部配置对象, 让 UI 能观察同一份 status / port。
    static func apply(configuration: CompanionConfiguration) {
        guard !TestEnvironment.isRunning,
              configuration.isEnabled,
              let dependencies else {
            stop()
            return
        }
        let provider = CompanionContextProvider(
            repoRepository: dependencies.repoRepository,
            noteRepository: dependencies.repoNoteRepository,
            tagRepository: dependencies.tagRepository,
            repoTagRepository: dependencies.repoTagRepository,
            summaryRepository: dependencies.aiSummaryRepository,
            healthRepository: dependencies.repoHealthRepository,
            openSSFRepository: dependencies.openSSFScoreRepository,
            wikiContextService: dependencies.wikiContextService,
            recommendationContextService: dependencies.recommendationContextService,
            entitlementGate: dependencies.entitlementGate
        )
        let noteWriter = CompanionNoteWriter(
            repoRepository: dependencies.repoRepository,
            noteRepository: dependencies.repoNoteRepository
        )
        let tagWriter = CompanionTagWriter(
            repoRepository: dependencies.repoRepository,
            tagRepository: dependencies.tagRepository,
            repoTagRepository: dependencies.repoTagRepository
        )
        let actionHandler = CompanionActionHandler(
            repoRepository: dependencies.repoRepository,
            dispatcher: dependencies.companionActionDispatcher,
            entitlementGate: dependencies.entitlementGate
        )
        let eventHub = CompanionEventHub(
            lookupTags: { repoID in
                let tags = try await dependencies.repoTagRepository.fetchTags(forRepo: repoID)
                return tags.map(CompanionContextProvider.tagDTO(_:))
            },
            lookupSummary: { repoID in
                try await dependencies.aiSummaryRepository.fetchLatestPerRepo()[repoID]
                    .flatMap(CompanionContextProvider.summaryDTO(_:))
            }
        )
        let nextServer = CompanionLocalServer(
            configuration: configuration,
            contextProvider: provider,
            noteWriter: noteWriter,
            tagWriter: tagWriter,
            actionHandler: actionHandler,
            eventHub: eventHub
        )
        server?.stop()
        server = nextServer
        nextServer.start()
    }

    static func stop() {
        server?.stop()
        server = nil
    }
}
