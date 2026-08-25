//
//  OpenRepositorySpotlightIntent.swift
//  Starcat
//
//  Spotlight 搜索结果点击后的系统打开动作。
//

import AppIntents

/// 把 Spotlight 中的仓库实体转换为主窗口的一次性导航请求。
///
/// `URLRepresentableIntent` 只支持 Universal Link，不能承载 Starcat 的自定义 scheme；
/// private repository 也不能借公开 URL 绕过现有隐私策略。因此由 OpenIntent 显式发布
/// 本机导航请求，再让 HomeView 的统一入口维护三栏状态。
struct OpenRepositorySpotlightIntent: OpenIntent {
    static let title: LocalizedStringResource = "spotlight.repository.open.title"

    @Dependency private var navigationDispatcher: MainWindowNavigationDispatcher

    @Parameter(title: "spotlight.repository.open.target")
    var target: RepositorySpotlightEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try navigate(using: navigationDispatcher)
        return .result()
    }

    /// 把纯目标映射和 App Intents 依赖解析分开，单测无需启动真实 Spotlight。
    @MainActor
    func navigate(using dispatcher: MainWindowNavigationDispatcher) throws {
        guard let repositoryID = Int64(target.repositoryID) else {
            throw NavigationError.invalidRepositoryTarget
        }
        dispatcher.navigate(to: .spotlightRepository(repositoryID))
    }

    private enum NavigationError: Error {
        case invalidRepositoryTarget
    }
}
