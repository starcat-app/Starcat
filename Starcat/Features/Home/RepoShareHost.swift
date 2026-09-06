//
//  RepoShareHost.swift
//  Starcat
//
//  仓库详情的窗口会话级分享宿主：统一持有任务、进度 Sheet、付费墙和完成反馈。
//  宿主挂在详情栏的场景分支外，Hero 只触发动作；切换仓库或收起 Sheet 不会销毁任务。
//

import SwiftUI

extension EnvironmentValues {
    /// 详情按钮把点击时的仓库快照交给稳定宿主，不自行持有 Sheet 或异步任务。
    @Entry var presentRepoShare: (Repo) -> Void = { _ in }
}

/// 主窗口详情栏和独立仓库窗口共用的分享 presentation host。
///
/// TaskStore 仍只依赖可测试的 operations；本层负责连接生产服务与 SwiftUI presentation。
/// 不能把本 modifier 挂到 `.id(repo.id)` 的子树内，否则切换仓库会丢失进度与恢复入口。
struct RepoShareHost: ViewModifier {
    @Environment(AppDependencies.self) private var dependencies
    @State private var taskStore = RepoShareTaskStore()
    @State private var presentation: RepoSharePresentation?
    @State private var completionMessage: String?
    @State private var paywallContext: ProPaywallContext?

    func body(content: Content) -> some View {
        content
            .environment(taskStore)
            .environment(\.presentRepoShare, presentOrStartShare)
            .toast(message: $completionMessage, icon: "link.circle")
            .sheet(item: $presentation) { presentation in
                RepoShareTaskSheet(
                    taskStore: taskStore,
                    repoID: presentation.repoID,
                    onCancel: { taskStore.cancel(repoID: presentation.repoID) },
                    onRetry: { retryShare(repoID: presentation.repoID) }
                )
                .id(presentation.repoID)
                .appLocaleEnvironment()
            }
            .sheet(item: $paywallContext) { context in
                ProPaywallSheet.hosted(context: context, dependencies: dependencies)
            }
            .onChange(of: taskStore.latestCompletion) { _, completion in
                guard let completion, presentation?.repoID != completion.repoID else { return }
                let key: String
                switch completion.outcome {
                case .success:
                    key = "repo.share.notification.successFormat"
                case .failure:
                    key = "repo.share.notification.failureFormat"
                }
                // 收起 Sheet 后仍标明原仓库名称，避免切换详情后把结果误认成当前仓库。
                completionMessage = String(format: String.l10n(key), completion.repoFullName)
            }
    }

    /// 同步登记任务再展示 Sheet；任务保存点击时快照，后续导航不改变请求目标。
    @MainActor
    private func presentOrStartShare(_ repo: Repo) {
        guard authorizeAIShare() else { return }
        taskStore.start(repo: repo, operations: shareOperations)
        presentation = RepoSharePresentation(repoID: repo.id)
    }

    /// 失败重试使用原任务保存的仓库，不读取当前详情选择。
    @MainActor
    private func retryShare(repoID: Int64) {
        guard authorizeAIShare() else { return }
        taskStore.retry(repoID: repoID, operations: shareOperations)
    }

    /// 基础链接不受登录 / Pro 限制；只有真正执行 AI 分享时才进行权限检查。
    @MainActor
    private func authorizeAIShare() -> Bool {
        guard dependencies.authSession.state.isAuthenticated else {
            dependencies.authSession.requestLoginSheet()
            return false
        }
        do {
            try dependencies.entitlementGate.requirePro(.aiSummary)
            return true
        } catch let error as EntitlementGateError {
            paywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
        } catch {
            paywallContext = ProPaywallContext(feature: .aiSummary, message: error.localizedDescription)
        }
        return false
    }

    /// 复用既有摘要缓存的语言回退规则，避免分享入口另做缓存选择或重复生成摘要。
    @MainActor
    private var shareOperations: RepoShareOperations {
        RepoShareOperations(
            cachedInsight: { repo in
                try await dependencies.repoAIInsightService.cachedInsightFast(for: repo)
            },
            generateInsight: { repo in
                (try await dependencies.repoAIInsightService.generateInsight(for: repo)).insight
            },
            createShare: { request in
                try await dependencies.shareAPI.shareRepo(request: request)
            }
        )
    }
}
