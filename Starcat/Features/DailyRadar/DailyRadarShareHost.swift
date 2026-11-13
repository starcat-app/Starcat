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
    var present: (DailyRadarReport) -> Void = { _ in }
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
            .environment(\.presentDailyRadarShare, DailyRadarSharePresenter(present: present))
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
        presentation = Presentation(id: report.contentIdentity)
    }

    private var shareOperations: DailyRadarShareOperations {
        DailyRadarShareOperations(
            renderCover: { try DailyRadarShareCover.render(report: $0) },
            createShare: { request, heroPNG in
                try await dependencies.shareAPI.shareDailyRadar(request: request, heroPNG: heroPNG)
            }
        )
    }
}
