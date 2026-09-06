//
//  ListInteractionEnvironment.swift
//  Starcat
//
//  长列表滚动期间的轻量交互门控环境值。
//

import Observation
import SwiftUI

/// 合并离散滚轮事件产生的 active / idle 抖动。
///
/// 鼠标滚轮可能让 `onScrollPhaseChange` 在很短时间内多次往返；如果直接把每次变化写进
/// `RepoListView.@State`，父视图会反复重算并重新生成整页 `IndexedRepo`。控制器只把真正的
/// “开始滚动”和防抖后的“结束滚动”发布给 SwiftUI，其余 Task 变更不参与 Observation。
@MainActor
@Observable
final class ListInteractionSuppressionController {
    private(set) var isSuppressed = false

    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    private let resumeDelay: Duration

    init(resumeDelay: Duration = .milliseconds(160)) {
        self.resumeDelay = resumeDelay
    }

    /// 接收系统滚动 phase；连续事件到来时不断顺延恢复，而不重复发布相同状态。
    func update(isActive: Bool) {
        resumeTask?.cancel()
        resumeTask = nil

        if isActive {
            guard !isSuppressed else { return }
            isSuppressed = true
            return
        }

        guard isSuppressed else { return }
        let delay = resumeDelay
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isSuppressed = false
            self?.resumeTask = nil
        }
    }

    /// View 生命周期结束时取消待恢复任务，避免旧列表实例延迟回写。
    func cancel() {
        resumeTask?.cancel()
        resumeTask = nil
        isSuppressed = false
    }
}

/// 列表正在跟随手势或惯性滚动时为 true。
///
/// 该值不改变分页和选择语义，只暂停 hover 动画、延迟预取等非必要工作。把状态放进
/// Environment 后，行组件无需持有列表级对象，也不会为每行建立独立滚动观察器。
private struct StarcatListInteractionSuppressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var starcatListInteractionSuppressed: Bool {
        get { self[StarcatListInteractionSuppressedKey.self] }
        set { self[StarcatListInteractionSuppressedKey.self] = newValue }
    }
}
