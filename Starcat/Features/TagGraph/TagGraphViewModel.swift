// 订阅当前账户的数据。选择和拖动仅更新画布，不触发数据库读取。
import Foundation
import GRDB
import Observation

/// 取消订阅后仍可能有回调在主队列等候。每次绑定或重试推进代次，丢弃旧账户的结果。
@MainActor @Observable final class TagGraphViewModel {
    private(set) var graph: TagGraphSnapshot?
    private(set) var revision = 0
    private(set) var generation = 0
    private(set) var failed = false
    @ObservationIgnored private var reader: (any DatabaseReader)?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var isCurrent: () -> Bool = { false }

    /// 宿主验证登录与数据库属于同一账户后绑定，旧快照先清除。
    func bind(reader: any DatabaseReader, isCurrent: @escaping () -> Bool) {
        clear()
        self.reader = reader
        self.isCurrent = isCurrent
        observe()
    }

    func clear() {
        observation?.cancel()
        observation = nil
        reader = nil
        isCurrent = { false }
        generation += 1
        graph = nil
        failed = false
    }

    func observe() {
        observation?.cancel()
        generation += 1
        let token = generation
        guard let reader, isCurrent() else { return }
        failed = false
        // GRDB 在数据库读取队列构造快照并比较内容；未改变的数据无需交付主线程。
        observation = ValueObservation.tracking { try TagGraphQuery.snapshot(in: $0) }
            .removeDuplicates()
            .start(in: reader, scheduling: .async(onQueue: .main), onError: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.accepts(generation: token) else { return }
                    self.failed = true
                }
            }, onChange: { [weak self] snapshot in
                MainActor.assumeIsolated { self?.apply(snapshot, generation: token) }
            })
    }

    func accepts(generation token: Int) -> Bool { token == generation && isCurrent() }

    func apply(_ snapshot: TagGraphSnapshot, generation token: Int) {
        guard accepts(generation: token) else { return }
        graph = snapshot
        revision += 1
        failed = false
    }
}
