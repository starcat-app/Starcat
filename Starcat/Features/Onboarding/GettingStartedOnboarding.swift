//
//  GettingStartedOnboarding.swift
//  Starcat
//
//  首次操作引导：负责用户进入主界面后的「下一步该做什么」清单。
//
//  设计边界：
//  - `FirstRunOnboardingView` 继续负责品牌 / 能力介绍；本文件只负责进入主界面后的操作闭环。
//  - 清单状态由真实行为推进（登录、同步、选中仓库、保存标签/笔记、搜索、打开 AI），避免用户只点「下一步」。
//  - TipKit 只用于局部发现提示，不承担任务进度；进度仍由 `GettingStartedProgressStore` 持久化。
//

import SwiftUI
import TipKit

// MARK: - Notification hooks

extension Notification.Name {
    /// 用户成功保存过标签或笔记后发出，驱动「整理一个仓库」清单项。
    static let gettingStartedDidOrganizeRepo = Notification.Name("starcat.gettingStarted.didOrganizeRepo")
    /// 用户提交过一次列表搜索后发出，驱动「使用搜索」清单项。
    static let gettingStartedDidUseSearch = Notification.Name("starcat.gettingStarted.didUseSearch")
    /// 用户打开过 AI 仓库助手后发出，驱动「试用 AI 摘要」清单项。
    static let gettingStartedDidOpenAI = Notification.Name("starcat.gettingStarted.didOpenAI")
}

// MARK: - Progress Store

/// 主界面首次操作清单的持久化状态。
///
/// 使用 `UserDefaults` 而不是数据库：这些状态是本机 UI 教程进度，不属于用户 GitHub 数据，
/// 账号切换也不应强制重播所有教学提示。恢复出厂路径会统一清理 onboarding key。
@MainActor
@Observable
final class GettingStartedProgressStore {

    enum StepID: String, CaseIterable, Identifiable {
        case signIn
        case syncStars
        case selectRepo
        case organizeRepo
        case useSearch
        case useAI

        var id: String { rawValue }
    }

    private enum Keys {
        static let completed = "onboarding.gettingStarted.completedSteps.v1"
        static let dismissed = "onboarding.gettingStarted.dismissed.v1"
        static let collapsed = "onboarding.gettingStarted.collapsed.v1"
    }

    private let defaults: UserDefaults

    private(set) var completedSteps: Set<StepID>

    var isDismissed: Bool {
        didSet { defaults.set(isDismissed, forKey: Keys.dismissed) }
    }

    var isCollapsed: Bool {
        didSet { defaults.set(isCollapsed, forKey: Keys.collapsed) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawValues = defaults.stringArray(forKey: Keys.completed) ?? []
        self.completedSteps = Set(rawValues.compactMap(StepID.init(rawValue:)))
        self.isDismissed = defaults.bool(forKey: Keys.dismissed)
        self.isCollapsed = defaults.bool(forKey: Keys.collapsed)
    }

    nonisolated static func resetPersistedState(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Keys.completed)
        defaults.removeObject(forKey: Keys.dismissed)
        defaults.removeObject(forKey: Keys.collapsed)
    }

    var completedCount: Int {
        completedSteps.count
    }

    var totalCount: Int {
        StepID.allCases.count
    }

    var isComplete: Bool {
        completedCount == totalCount
    }

    func isCompleted(_ step: StepID) -> Bool {
        completedSteps.contains(step)
    }

    func markCompleted(_ step: StepID) {
        guard completedSteps.insert(step).inserted else { return }
        persistCompletedSteps()
    }

    func reset() {
        completedSteps.removeAll()
        isDismissed = false
        isCollapsed = false
        defaults.removeObject(forKey: Keys.completed)
    }

    private func persistCompletedSteps() {
        let values = completedSteps.map(\.rawValue).sorted()
        defaults.set(values, forKey: Keys.completed)
    }
}

// MARK: - TipKit

/// TipKit 的提示定义集中在一处，避免各个 toolbar / section 分散创建匿名 tip。
///
/// TipKit 展示次数与失效状态由系统管理；清单完成状态由 `GettingStartedProgressStore` 管理，
/// 二者故意分离，避免用户关闭 tip 后误判为已经完成任务。
enum GettingStartedTips {
    struct SyncStarsTip: Tip {
        var title: Text { Text("gettingStarted.tip.sync.title") }
        var message: Text? { Text("gettingStarted.tip.sync.message") }
        var image: Image? { Image(systemName: "arrow.triangle.2.circlepath") }
    }

    struct SearchTip: Tip {
        var title: Text { Text("gettingStarted.tip.search.title") }
        var message: Text? { Text("gettingStarted.tip.search.message") }
        var image: Image? { Image(systemName: "magnifyingglass") }
    }

    struct AITip: Tip {
        var title: Text { Text("gettingStarted.tip.ai.title") }
        var message: Text? { Text("gettingStarted.tip.ai.message") }
        var image: Image? { Image(systemName: "sparkles") }
    }

    static let syncStars = SyncStarsTip()
    static let search = SearchTip()
    static let ai = AITip()
}

// MARK: - Checklist View

struct GettingStartedChecklistView: View {
    let store: GettingStartedProgressStore
    let isSignedIn: Bool
    let hasSyncedStars: Bool
    let hasSelectedRepo: Bool
    let canSelectRepo: Bool

    let onSignIn: () -> Void
    let onSyncStars: () -> Void
    let onSelectRepo: () -> Void
    let onOpenSearch: () -> Void
    let onOpenAI: () -> Void

    @Environment(\.starcatReduceMotion) private var reduceMotion

    private let cardWidth: CGFloat = 340

    private var shouldRender: Bool {
        !store.isDismissed && !store.isComplete
    }

    private var progressValue: Double {
        guard store.totalCount > 0 else { return 1 }
        return Double(store.completedCount) / Double(store.totalCount)
    }

    private var steps: [GettingStartedStep] {
        [
            GettingStartedStep(
                id: .signIn,
                title: "gettingStarted.step.signIn.title",
                detail: "gettingStarted.step.signIn.detail",
                systemImage: "person.crop.circle.badge.checkmark",
                actionTitle: "gettingStarted.step.signIn.action",
                isAvailable: !isSignedIn,
                action: onSignIn
            ),
            GettingStartedStep(
                id: .syncStars,
                title: "gettingStarted.step.sync.title",
                detail: "gettingStarted.step.sync.detail",
                systemImage: "arrow.triangle.2.circlepath",
                actionTitle: "gettingStarted.step.sync.action",
                isAvailable: isSignedIn && !hasSyncedStars,
                action: onSyncStars
            ),
            GettingStartedStep(
                id: .selectRepo,
                title: "gettingStarted.step.select.title",
                detail: "gettingStarted.step.select.detail",
                systemImage: "cursorarrow.click.2",
                actionTitle: "gettingStarted.step.select.action",
                isAvailable: canSelectRepo && !hasSelectedRepo,
                action: onSelectRepo
            ),
            GettingStartedStep(
                id: .organizeRepo,
                title: "gettingStarted.step.organize.title",
                detail: "gettingStarted.step.organize.detail",
                systemImage: "tag",
                actionTitle: "gettingStarted.step.organize.action",
                isAvailable: hasSelectedRepo,
                action: onSelectRepo
            ),
            GettingStartedStep(
                id: .useSearch,
                title: "gettingStarted.step.search.title",
                detail: "gettingStarted.step.search.detail",
                systemImage: "magnifyingglass",
                actionTitle: "gettingStarted.step.search.action",
                isAvailable: true,
                action: onOpenSearch
            ),
            GettingStartedStep(
                id: .useAI,
                title: "gettingStarted.step.ai.title",
                detail: "gettingStarted.step.ai.detail",
                systemImage: "sparkles",
                actionTitle: "gettingStarted.step.ai.action",
                isAvailable: hasSelectedRepo,
                action: onOpenAI
            )
        ]
    }

    var body: some View {
        if shouldRender {
            VStack(alignment: .leading, spacing: 12) {
                header

                if !store.isCollapsed {
                    Divider()

                    VStack(spacing: 0) {
                        ForEach(steps) { step in
                            GettingStartedStepRow(
                                step: step,
                                isCompleted: store.isCompleted(step.id)
                            )

                            if step.id != steps.last?.id {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: cardWidth, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 8)
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("gettingStarted.title")
                        .font(.headline)
                    Text("gettingStarted.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    store.isCollapsed.toggle()
                } label: {
                    Image(systemName: store.isCollapsed ? "chevron.up" : "chevron.down")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help(store.isCollapsed ? Text("gettingStarted.expand") : Text("gettingStarted.collapse"))

                Button {
                    store.isDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("gettingStarted.dismiss")
            }

            ProgressView(value: progressValue)
                .controlSize(.small)

            Text(String(format: String.l10n("gettingStarted.progressFormat"), store.completedCount, store.totalCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct GettingStartedStep: Identifiable {
    let id: GettingStartedProgressStore.StepID
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    let actionTitle: LocalizedStringKey
    let isAvailable: Bool
    let action: () -> Void
}

private struct GettingStartedStepRow: View {
    let step: GettingStartedStep
    let isCompleted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : step.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCompleted ? .green : Color.accentColor)
                .frame(width: 22, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(step.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isCompleted {
                Button(action: step.action) {
                    Text(step.actionTitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .disabled(!step.isAvailable)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
