//
//  CompanionServiceBootstrapper.swift
//  Starcat
//
//  Chrome Companion 本机服务启动门控。
//
//  设计约束:
//  - Companion v1 仍是未发布能力, Release 包必须编译为 no-op;
//  - 测试 host 必须先跳过, 避免为了读取 token 触发 Keychain 授权弹窗;
//  - Debug flag 与配置 enabled 双门控, 防止用户配置残留导致服务自动暴露;
//  - 持有 server 单例, 避免 NWListener 在启动函数返回后被释放。
//

import Foundation

@MainActor
enum CompanionServiceBootstrapper {
    private static var server: CompanionLocalServer?
    private static var dependencies: AppDependencies?

    /// App 启动期调用。只有 DEBUG + 显式调试开关 + Companion 配置 enabled 都满足时才启动。
    static func startFromStoredConfiguration(dependencies: AppDependencies) {
        #if DEBUG
        self.dependencies = dependencies
        guard !TestEnvironment.isRunning, DebugFlags.companionLocalServer else { return }
        apply(configuration: CompanionConfiguration())
        #endif
    }

    /// Debug 菜单运行期调用。这里接收外部配置对象, 便于测试和菜单动作复用同一份状态。
    static func apply(configuration: CompanionConfiguration) {
        #if DEBUG
        guard !TestEnvironment.isRunning,
              DebugFlags.companionLocalServer,
              configuration.isEnabled,
              let dependencies else {
            stop()
            return
        }
        let provider = CompanionContextProvider(
            repoRepository: dependencies.repoRepository,
            noteRepository: dependencies.repoNoteRepository,
            healthRepository: dependencies.repoHealthRepository,
            openSSFRepository: dependencies.openSSFScoreRepository,
            wikiContextService: dependencies.wikiContextService,
            recommendationContextService: dependencies.recommendationContextService
        )
        let noteWriter = CompanionNoteWriter(
            repoRepository: dependencies.repoRepository,
            noteRepository: dependencies.repoNoteRepository
        )
        let actionHandler = CompanionActionHandler(
            repoRepository: dependencies.repoRepository,
            dispatcher: dependencies.companionActionDispatcher
        )
        let nextServer = CompanionLocalServer(
            configuration: configuration,
            contextProvider: provider,
            noteWriter: noteWriter,
            actionHandler: actionHandler
        )
        server?.stop()
        server = nextServer
        nextServer.start()
        #else
        configuration.updateServerStatus(.stopped)
        #endif
    }

    static func stop() {
        server?.stop()
        server = nil
    }
}
