//
//  DailyRadarShareHost.swift
//  Starcat
//
//  日报分享挂在稳定工作区，持有点击时快照；切换文章或关闭 Sheet 不会串改任务。
//

import SwiftUI

extension EnvironmentValues {
    @Entry var presentDailyRadarShare: DailyRadarSharePresenter = DailyRadarSharePresenter()
}

/// 包装环境 closure，沿用 RepoSharePresenter 的值语义，避免 @Entry 比较裸 closure。
struct DailyRadarSharePresenter {
    var serviceIdentity: String = ""
    var present: (DailyRadarReport) -> Void = { _ in }
    var restore: (DailyRadarReport) async -> Void = { _ in }
}

/// 工作区只负责装配服务与展示，分享任务不依赖当前选中的文章。
struct DailyRadarShareHost: ViewModifier {
    private struct Presentation: Identifiable {
        let id: String
    }

    @Environment(AppDependencies.self) private var dependencies
    @State private var taskStore = DailyRadarShareTaskStore()
    @State private var presentation: Presentation?

    func body(content: Content) -> some View {
        content
            .environment(taskStore)
            .environment(\.presentDailyRadarShare, DailyRadarSharePresenter(
                serviceIdentity: serviceIdentity, present: present,
                restore: { await taskStore.restore(report: $0, operations: shareOperations, legacyShare: restoreLegacyShare) }
            ))
            .sheet(item: $presentation) { selected in
                DailyRadarShareSheet(
                    taskStore: taskStore, identity: selected.id,
                    onRetry: { taskStore.retry(identity: selected.id, operations: shareOperations) }
                )
                .appLocaleEnvironment()
            }
    }

    /// 同步发布生成态，再打开 Sheet；重复点击恢复原任务，不读取全局 Repo 或账号状态。
    private func present(_ report: DailyRadarReport) {
        taskStore.start(report: report, operations: shareOperations)
        presentation = Presentation(id: DailyRadarShareTaskStore.identity(report: report, serviceIdentity: serviceIdentity))
    }

    private var serviceIdentity: String {
        dependencies.settings.customServiceURL(for: .sharing) ?? AppEndpoints.Sharing.productionURL.absoluteString
    }

    private var shareOperations: DailyRadarShareOperations {
        let selectedService = serviceIdentity
        return DailyRadarShareOperations(
            renderCover: { try DailyRadarShareCover.render(report: $0) },
            createShare: { request, heroPNG in
                guard serviceIdentity == selectedService else { throw DailyRadarShareError.configuration }
                return try await dependencies.shareAPI.shareDailyRadar(request: request, heroPNG: heroPNG)
            },
            serviceIdentity: selectedService,
            cachedShare: { report in
                await dependencies.shareAPI.cachedDailyRadarShare(
                    reportID: report.id, language: report.contentLanguage, revision: report.revision
                )
            },
            lookupShare: { report in
                guard serviceIdentity == selectedService else { throw DailyRadarShareError.configuration }
                return try await dependencies.shareAPI.lookupDailyRadarShare(
                    reportID: report.id, language: report.contentLanguage, revision: report.revision
                )
            }
        )
    }

    /// 旧文件只有哈希索引，仅在恢复旧本地记录时按旧算法重建封面。
    private func restoreLegacyShare(_ report: DailyRadarReport) async -> DailyRadarShareResponse? {
        let api = dependencies.shareAPI
        guard await api.hasLegacyDailyRadarShares(),
              let request = try? DailyRadarShareRequest(detail: report),
              let cover = try? DailyRadarShareCover.render(report: report) else { return nil }
        return await api.cachedDailyRadarShare(request: request, heroPNG: cover.png)
    }
}
