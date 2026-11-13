//
//  RepoSkillSession.swift
//  Starcat
//
//  多目录安装会话：队列以 Skill 与目录的组合计数，安装状态以真实文件校验为准。
//

import AppKit
import Foundation
import Observation

/// 来源、目录与选择在批次开始时冻结，取消或切账号后不再发布后续目录。
@MainActor
@Observable
final class RepoSkillSession {
    enum Phase { case ready, running, finished, cancelled }
    enum Status { case waiting, copying, succeeded, failed, cancelled }

    /// 同一个 Skill 的各目录独立完成、失败或重试，避免一处成功掩盖另一处失败。
    @Observable
    final class Item: Identifiable {
        let skill: RepoSkill
        let destination: RepoSkillDestination
        var status: Status = .waiting
        var progress = 0.0
        var error: String?
        let id: String

        init(skill: RepoSkill, destination: RepoSkillDestination) {
            self.skill = skill
            self.destination = destination
            self.id = skill.id + "|" + destination.id
        }
    }

    /// 分组只在队列成员改变时建立，单项下载进度由 Item 自己发布。
    struct ItemGroup: Identifiable {
        let skill: RepoSkill
        let items: [Item]
        var id: String { skill.id }
    }

    struct DestinationCheck {
        var installed: Set<String> = []
        var conflicts: Set<String> = []
        var error: String?
    }

    let repo: Repo
    @ObservationIgnored let readingCache = RepoSkillReadingCache()
    private let store: RepoSkillStore
    private let installer: RepoSkillInstaller
    private let accountRevision: UInt64
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var destinations: [RepoSkillDestination]
    private(set) var selectedDestinationIDs: Set<String> = []
    private(set) var checks: [String: DestinationCheck] = [:]
    private(set) var scan: RepoSkillScan?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isCheckingDestination = false
    private(set) var selectedIDs: Set<String> = []
    private(set) var phase = Phase.ready
    private(set) var queue: [Item] = []
    private(set) var replacements: Set<String> = []
    private(set) var skipped: Set<String> = []
    private(set) var installedIDs: Set<String> = []
    private(set) var selectedDestinations: [RepoSkillDestination] = []
    private(set) var pendingSkills: [RepoSkill] = []
    private(set) var plannedItems: [Item] = []
    private(set) var conflicts: [Item] = []
    private(set) var hasDuplicateNames = false
    private(set) var plannedGroups: [ItemGroup] = []
    private(set) var queueGroups: [ItemGroup] = []
    private(set) var coverageCounts: [String: Int] = [:]
    /// 列表只随目录覆盖或扫描成员变化更新，下载进度不使搜索结果失效。
    private(set) var listRevision: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var destinationRevision: UInt64 = 0
    @ObservationIgnored private var scopedURLs: [String: URL] = [:]
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var hasAppliedSingleSkillDefault = false
    @ObservationIgnored private var directoriesPrepared: Bool

    private static let selectedKey = "skills.install.destinations.selected"
    private static let bookmarksKey = "skills.install.destinations.bookmarks"

    /// 测试可注入临时目录与独立 defaults，绝不写入使用者的真实工具目录或偏好。
    init(repo: Repo, store: RepoSkillStore, destinations: [RepoSkillDestination]? = nil,
         defaults: UserDefaults = .standard) {
        self.repo = repo
        self.store = store
        self.accountRevision = store.accountRevision
        self.installer = RepoSkillInstaller(downloader: store.downloader(for: repo))
        self.defaults = defaults
        self.destinations = destinations ?? []
        self.directoriesPrepared = destinations != nil
        restoreSelection()
        rebuildCoverage()
    }

    var skills: [RepoSkill] { scan?.skills ?? [] }
    var scanProgressText: String? {
        guard isLoading, let scan else { return nil }
        let checked = scan.manifestChecked ?? scan.skills.count
        let total = scan.manifestTotal ?? max(scan.skills.count, checked)
        return String(format: String.l10n("repo.skills.scan.progress"), checked, total)
    }
    var isExport: Bool {
        !DistributionChannel.current.isDirect
            || (!selectedDestinations.isEmpty && selectedDestinations.allSatisfy { $0.preset == nil })
    }
    var isInstalling: Bool { phase == .running }
    var hasFailures: Bool { queue.contains { $0.status == .failed } }
    var canStart: Bool {
        !isClosed && store.accountRevision == accountRevision && !store.isChangingAccount
            && !isInstalling && !isLoading && !isCheckingDestination && scan != nil
            && !plannedItems.isEmpty && conflicts.isEmpty && !hasDuplicateNames
            && selectedDestinations.allSatisfy { checks[$0.id] != nil && checks[$0.id]?.error == nil }
            && pendingSkills.allSatisfy { $0.installationIssue == nil }
    }
    var displayedQueue: [Item] { phase == .ready ? plannedItems : queue }
    var displayedGroups: [ItemGroup] { phase == .ready ? plannedGroups : queueGroups }

    func coverage(of skillID: String) -> Int {
        coverageCounts[skillID, default: 0]
    }

    /// 单项默认选中；集合保持按需选择，重新扫描会清除不再存在的 Skill。
    func load(force: Bool = false) async {
        guard !isClosed, store.accountRevision == accountRevision, !isInstalling, !isLoading else { return }
        isLoading = true
        let loading = Task { [weak self] in
            guard let self else { return }
            await self.loadScan(force: force)
        }
        scanTask = loading
        await withTaskCancellationHandler {
            await loading.value
        } onCancel: {
            loading.cancel()
        }
        scanTask = nil
        isLoading = false
    }

    /// 会话持有扫描任务，手动刷新产生的非结构化入口也能在关窗时取消订阅。
    private func loadScan(force: Bool) async {
        error = nil
        if force { hasAppliedSingleSkillDefault = false }
        do {
            await prepareDirectories()
            try Task.checkCancellation()
            guard !isClosed else { return }
            let result = try await store.detect(repo, force: force) { [weak self] partial in
                // 首个有效 Skill 到达即进入窗口；集合未查完前不自动默认勾选。
                self?.applyScan(partial, isPartial: true)
            }
            try Task.checkCancellation()
            guard !isClosed else { return }
            applyScan(result, isPartial: false)
            await checkDestinations()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// 预览与安装固定同一提交，账号切换后拒绝迟到的读取结果。
    func preview(file: RepoSkillFile, skill: RepoSkill) async throws -> RepoFilePreview {
        guard !isClosed, store.accountRevision == accountRevision, !store.isChangingAccount else { throw CancellationError() }
        let value = try await store.downloader(for: repo).preview(
            owner: repo.owner, repo: repo.name, sha: file.sha,
            relativePath: skill.directory + file.path, hintedSize: file.size
        )
        try Task.checkCancellation()
        guard !isClosed, store.accountRevision == accountRevision, !store.isChangingAccount else { throw CancellationError() }
        return value
    }

    func refreshDestination() async {
        guard !isClosed, !isInstalling, directoriesPrepared, !isLoading else { return }
        await checkDestinations()
    }

    func toggleDestination(_ id: String) {
        guard !isInstalling, directoriesPrepared else { return }
        if selectedDestinationIDs.contains(id) { selectedDestinationIDs.remove(id) } else { selectedDestinationIDs.insert(id) }
        destinationsChanged()
    }

    func selectAllDestinations(_ selected: Bool) {
        guard !isInstalling, directoriesPrepared else { return }
        selectedDestinationIDs = selected ? Set(destinations.map(\.id)) : []
        destinationsChanged()
    }

    /// 系统选择器是沙盒目录授权的唯一入口；书签保留原始 URL，不用解析后的 URL 替代授权。
    func chooseDirectory() {
        guard !isInstalling, directoriesPrepared else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            Task { @MainActor in await self?.addDirectory(url) }
        }
    }

    /// 同一目录再次加入只勾选已有条目，不生成重复安装任务。
    func addDirectory(_ url: URL) async {
        guard !isInstalling, directoriesPrepared else { return }
        let destination = await Self.resolveDirectory(url)
        guard !isClosed, !isInstalling, store.accountRevision == accountRevision else { return }
        if !destinations.contains(where: { $0.id == destination.id }) {
            destinations.append(destination)
            if url.startAccessingSecurityScopedResource() { scopedURLs[destination.id] = url }
            persistDirectories()
        }
        selectedDestinationIDs.insert(destination.id)
        destinationsChanged()
    }

    func removeDirectory(_ id: String) {
        guard !isInstalling, destinations.contains(where: { $0.id == id && $0.preset == nil }) else { return }
        destinations.removeAll { $0.id == id }
        selectedDestinationIDs.remove(id)
        scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        persistDirectories()
        destinationsChanged()
    }

    func toggleSelection(_ id: String) {
        guard !isInstalling, !installedIDs.contains(id) else { return }
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        resetPlan()
    }

    func selectAll(_ selected: Bool) {
        guard !isInstalling else { return }
        let installed = installedIDs
        selectedIDs = selected ? Set(skills.filter { !installed.contains($0.id) && $0.installationIssue == nil }.map(\.id)) : []
        resetPlan()
    }

    /// 跳过与替换均只作用于当前「Skill × 目录」，不改变其它目录的决策。
    func resolveConflict(_ id: String, replacing: Bool) {
        guard !isInstalling else { return }
        if replacing { replacements.insert(id) } else { skipped.insert(id) }
        resetPlan()
    }

    /// 批次冻结目录；部分失败只重试失败组合，取消后继续只发布尚未完成的目录。
    func start() {
        guard canStart else { return }
        let failedIDs = Set(queue.filter { $0.status == .failed }.map(\.id))
        let items = plannedItems.filter { phase != .finished || !hasFailures || failedIDs.contains($0.id) }
        guard !items.isEmpty else { return }
        if phase == .finished && hasFailures {
            for index in queue.indices where failedIDs.contains(queue[index].id) {
                queue[index].status = .waiting
                queue[index].progress = 0
                queue[index].error = nil
            }
        } else {
            queue = items
        }
        queueGroups = Self.group(queue)
        let revision = destinationRevision
        let installationID = UUID()
        phase = .running
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.store.finishInstallation(id: installationID) }
            for item in items {
                if Task.isCancelled { break }
                self.update(item.id, status: .copying)
                let itemID = item.id
                do {
                    try await self.installer.install(
                        item.skill, repo: self.repo, destination: item.destination,
                        replacing: self.replacements.contains(item.id),
                        onProgress: { [weak self] progress in
                            Task { @MainActor in
                                guard let self, self.isInstalling, self.destinationRevision == revision,
                                      let index = self.queue.firstIndex(where: { $0.id == itemID }),
                                      self.queue[index].status == .copying else { return }
                                self.queue[index].progress = progress
                            }
                        }
                    )
                    // 同卷发布已完成就保留成功事实，不让稍后到达的取消信号把它改成失败。
                    self.checks[item.destination.id, default: DestinationCheck()].installed.insert(item.skill.id)
                    self.checks[item.destination.id]?.conflicts.remove(item.skill.id)
                    self.replacements.remove(item.id)
                    self.update(item.id, status: .succeeded)
                    self.rebuildCoverage()
                } catch {
                    if case RepoSkillError.conflict = error {
                        self.checks[item.destination.id, default: DestinationCheck()].conflicts.insert(item.skill.id)
                    }
                    self.update(item.id, status: Task.isCancelled ? .cancelled : .failed, error: error.localizedDescription)
                }
            }
            for index in self.queue.indices where self.queue[index].status == .waiting {
                self.queue[index].status = .cancelled
            }
            self.phase = Task.isCancelled ? .cancelled : .finished
            self.rebuildPlan()
            self.task = nil
            if self.isClosed { self.stopAccessingDirectories() }
        }
        if let task { store.trackInstallation(task, id: installationID) }
    }

    func cancel() { task?.cancel() }

    /// 等待安装清理 staging 后才释放目录授权，避免取消过程中丢失写入权限。
    func close() {
        isClosed = true
        destinationRevision &+= 1
        scanTask?.cancel()
        cancel()
        if !isInstalling { stopAccessingDirectories() }
    }

    private func update(_ id: String, status: Status, error: String? = nil) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].status = status
        queue[index].error = error
        if status == .succeeded { queue[index].progress = 1 }
    }

    private func destinationsChanged() {
        defaults.set(Array(selectedDestinationIDs).sorted(), forKey: Self.selectedKey)
        replacements = []
        skipped = []
        rebuildCoverage()
        resetPlan()
        // 同步置为 checking，避免下一次 Task 开始前按钮短暂可用。
        destinationRevision &+= 1
        isCheckingDestination = true
        Task { await checkDestinations() }
    }

    /// 目录或扫描改变后重新核对，修订号防止旧异步检查覆盖新目录状态。
    private func checkDestinations() async {
        guard !isClosed else { return }
        destinationRevision &+= 1
        let revision = destinationRevision
        isCheckingDestination = true
        defer { if revision == destinationRevision { isCheckingDestination = false } }
        for destination in destinations {
            var check = DestinationCheck()
            for skill in skills {
                do {
                    switch try await installer.existing(skill, destination: destination) {
                    case .installed: check.installed.insert(skill.id)
                    case .conflict: check.conflicts.insert(skill.id)
                    case .missing: break
                    }
                } catch { check.error = error.localizedDescription }
                guard revision == destinationRevision, !isClosed else { return }
            }
            checks[destination.id] = check
        }
        rebuildCoverage()
    }

    private func resetPlan() {
        queue = []
        queueGroups = []
        phase = .ready
        rebuildPlan()
    }

    /// 所有派生状态集中失效：行只做 O(1) 查询，不能在每行的 body 中重新遍历全量 Skill。
    /// 未选目录不算已安装；软链接别名通过预先解析的身份去重。
    private func rebuildCoverage() {
        var paths: Set<String> = []
        selectedDestinations = destinations.filter {
            selectedDestinationIDs.contains($0.id) && paths.insert($0.id).inserted
        }
        var counts: [String: Int] = [:]
        for destination in selectedDestinations {
            for id in checks[destination.id]?.installed ?? [] { counts[id, default: 0] += 1 }
        }
        coverageCounts = counts
        let required = selectedDestinations.count
        installedIDs = required == 0 ? [] : Set(skills.lazy.filter { counts[$0.id] == required }.map(\.id))
        listRevision &+= 1
        if isInstalling {
            // 批次成员已经冻结，单项完成只更新覆盖，不重新分配整个 Skill × 目录计划。
            pendingSkills = skills.filter { selectedIDs.contains($0.id) && !installedIDs.contains($0.id) }
        } else {
            rebuildPlan()
        }
    }

    /// 选择、目录或冲突变化才重建计划；进度回调不参与队列推导。
    private func rebuildPlan() {
        pendingSkills = skills.filter { selectedIDs.contains($0.id) && !installedIDs.contains($0.id) }
        hasDuplicateNames = Set(pendingSkills.map(\.name)).count != pendingSkills.count
        plannedItems = pendingSkills.flatMap { skill in
            selectedDestinations.compactMap { destination -> Item? in
                let item = Item(skill: skill, destination: destination)
                guard !skipped.contains(item.id), checks[destination.id]?.installed.contains(skill.id) != true else { return nil }
                return item
            }
        }
        conflicts = plannedItems.filter {
            checks[$0.destination.id]?.conflicts.contains($0.skill.id) == true && !replacements.contains($0.id)
        }
        plannedGroups = Self.group(plannedItems)
    }

    private static func group(_ items: [Item]) -> [ItemGroup] {
        var grouped: [String: [Item]] = [:]
        var order: [RepoSkill] = []
        for item in items {
            if grouped[item.skill.id] == nil { order.append(item.skill) }
            grouped[item.skill.id, default: []].append(item)
        }
        return order.map { ItemGroup(skill: $0, items: grouped[$0.id, default: []]) }
    }

    /// 渐进结果只用于阅读和进度；最终结果才允许进入目录核对和安装准备。
    private func applyScan(_ value: RepoSkillScan, isPartial: Bool) {
        guard !isClosed, store.accountRevision == accountRevision, !store.isChangingAccount, !isInstalling else { return }
        scan = value
        selectedIDs.formIntersection(Set(skills.map(\.id)))
        if !isPartial, !hasAppliedSingleSkillDefault, skills.count == 1 {
            selectedIDs = [skills[0].id]
            hasAppliedSingleSkillDefault = true
        }
        rebuildCoverage()
        resetPlan()
    }

    private func restoreSelection() {
        let available = Set(destinations.map(\.id))
        if let stored = defaults.stringArray(forKey: Self.selectedKey) {
            selectedDestinationIDs = Set(stored).intersection(available)
        } else if let first = destinations.first {
            selectedDestinationIDs = [first.id]
        }
    }

    /// 书签和软链接解析可能等磁盘或挂载点，窗口先显示，后台准备好再发布轻量目录快照。
    private func prepareDirectories() async {
        guard !directoriesPrepared else { return }
        let setup = await Self.resolveDirectories(
            presets: DistributionChannel.current.isDirect ? RepoSkillTargetPreset.allCases : [],
            bookmarks: defaults.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        )
        guard !isClosed, !Task.isCancelled, store.accountRevision == accountRevision else {
            for url in setup.scoped.values { url.stopAccessingSecurityScopedResource() }
            return
        }
        destinations = setup.destinations
        scopedURLs = setup.scoped
        directoriesPrepared = true
        restoreSelection()
        rebuildCoverage()
    }

    @concurrent private nonisolated static func resolveDirectory(_ url: URL) async -> RepoSkillDestination {
        RepoSkillDestination(preset: nil, url: url)
    }

    /// 授权 URL 和物理目录身份分别保存：前者维持沙盒授权，后者用于别名去重。
    @concurrent private nonisolated static func resolveDirectories(
        presets: [RepoSkillTargetPreset], bookmarks: [Data]
    ) async -> (destinations: [RepoSkillDestination], scoped: [String: URL]) {
        var destinations = presets.map { RepoSkillDestination(preset: $0, url: $0.defaultURL) }
        var scoped: [String: URL] = [:]
        for data in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                    relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { continue }
            let destination = RepoSkillDestination(preset: nil, url: url)
            guard !destinations.contains(where: { $0.id == destination.id }) else { continue }
            destinations.append(destination)
            if url.startAccessingSecurityScopedResource() { scoped[destination.id] = url }
        }
        return (destinations, scoped)
    }

    private func persistDirectories() {
        do {
            let bookmarks = try destinations.filter { $0.preset == nil }.map {
                try $0.url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            defaults.set(bookmarks, forKey: Self.bookmarksKey)
        } catch { self.error = error.localizedDescription }
    }

    private func stopAccessingDirectories() {
        for url in scopedURLs.values { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }
}
