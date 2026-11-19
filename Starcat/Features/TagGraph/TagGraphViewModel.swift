// 订阅图谱并管理账户、选择与分页的生命周期。
import Foundation
import GRDB
import Observation

/// 每次绑定捕获具体数据库。取消订阅和校验代次共同阻止晚到的回调覆盖新选择。
@MainActor @Observable final class TagGraphViewModel {
    static let pageSize = 20
    private(set) var graph: TagGraphSnapshot?
    private(set) var selection: TagGraphSelection?
    private(set) var page: RepoTagIntersectionPage?
    private(set) var offset = 0
    private(set) var failed = false
    private(set) var selectionDisappeared = false
    private(set) var session = UUID()
    private(set) var generation = 0
    var search = ""
    var minimum = 1
    var showsAll = false
    @ObservationIgnored private var reader: (any DatabaseReader)?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var isCurrent: () -> Bool = { false }

    /// 由宿主在登录账户与数据库账户相符时调用。关窗和切号首先清除旧内容。
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
        session = UUID()
        generation += 1
        graph = nil
        selection = nil
        page = nil
        offset = 0
        showsAll = false
        selectionDisappeared = false
        search = ""
        minimum = 1
        failed = false
    }

    func select(_ next: TagGraphSelection?) {
        guard isCurrent(), next != selection, next == nil || graph.map({ next?.exists(in: $0) == true }) == true else { return }
        selection = next
        selectionDisappeared = false
        showsAll = false
        offset = 0
        page = nil
        observe()
    }

    func turnPage(to newOffset: Int) {
        guard isCurrent(), let page, (0..<page.total).contains(newOffset), newOffset != offset else { return }
        offset = newOffset
        self.page = nil
        observe()
    }

    /// 捕获选中项与页码，在 GRDB 读取队列生成整帧，主线程只发布当前订阅的结果。
    func observe() {
        observation?.cancel()
        generation += 1
        let token = generation
        guard let reader, isCurrent() else { return }
        failed = false
        let selection = self.selection, offset = self.offset, limit = Self.pageSize
        observation = ValueObservation.tracking { db in
            try TagGraphFrame.read(in: db, selection: selection, offset: offset, limit: limit)
        }.start(in: reader, scheduling: .async(onQueue: .main), onError: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.accepts(generation: token) else { return }
                self.failed = true
            }
        }, onChange: { [weak self] frame in
            MainActor.assumeIsolated { self?.apply(frame, generation: token) }
        })
    }

    func accepts(generation token: Int) -> Bool { token == generation && isCurrent() }

    /// WKWebView 消息还要匹配所属画布和它上次呈现的选择代次。
    func accepts(session: UUID, generation: Int) -> Bool {
        self.session == session && accepts(generation: generation)
    }

    func apply(_ frame: TagGraphFrame, generation token: Int) {
        guard accepts(generation: token) else { return }
        if graph != frame.graph { graph = frame.graph }
        page = frame.page
        failed = false
        if selection != nil && frame.page == nil {
            select(nil)
            selectionDisappeared = true
        } else if frame.offset != offset {
            offset = frame.offset
            observe()
        }
    }
}
