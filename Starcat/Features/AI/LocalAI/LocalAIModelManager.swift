//
//  LocalAIModelManager.swift
//  Starcat
//
//  本地 AI 模型管理器：下载 / 暂停 / 删除 / 安装状态 + 内置 profile 同步。
//
//  架构：
//  - `LocalAIModelManager`（@MainActor @Observable）：设置页直接观察的状态机。
//    下载重活交给 `LocalAIModelDownloader`（actor）与 `LocalAIModelStorage`（纯函数）。
//  - 内置 profile：`AIProviderProfile` 的 selection 解析只卡 `isVerifiedConfiguration`
//    （= isEnabled && lastTestStatus.isSuccess），因此本地接入的最小适配是维护一个固定
//    id 的内置 profile：模型安装状态变化时同步 `models`（AIModelDescriptor 列表）与
//    `lastTestStatus`。任务模型 picker、capability 校验、`hasConfiguredChatModel`
//    全部复用现有逻辑，零分支。
//  - 免费：本地 AI 不做 Pro 门控；门控放行由 EntitlementGate 侧按 provider 判断。
//
//  关键约束：
//  - `TestEnvironment.isRunning` 时 `shared` 为 no-op 状态：不发起下载、不触发 MLX。
//  - manifest.json 是安装状态单一真源；本机的 `installStates` 只是 UI 快照，
//    启动时从磁盘 `listInstalled()` 重建。
//

import Foundation
import Observation

/// 设置页观察的单模型下载状态。
///
/// `downloading` 携带的是**整个模型**的真实落盘字节进度，而不是当前文件的进度：
/// 小配置文件与 GB 级权重按各自真实体积累计。速度为 EMA 平滑值，首个采样窗口内为 nil。
enum LocalAIInstallState: Equatable, Sendable {
    case idle
    case preparing
    case downloading(
        progress: Double, completedBytes: Int64, totalBytes: Int64, speedBytesPerSecond: Double?)
    case failed(message: String)
    /// 下载完成后自动进入：完整性检查通过后的 MLX 权重加载阶段（不确定进度，薄荷色条）。
    case loading
    /// 容器加载失败（如 mxfp8 在老芯片上不受支持）：文件已装好，可单独重试加载。
    case loadFailed(message: String)
    /// 正等待本进程 / 另一渠道释放模型文件，或正在删除目录。
    case deleting
    /// 删除失败时模型仍保留，可由用户再次删除。
    case deleteFailed(message: String)
    case installed

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// ModelScope `/repo/files` 的最小响应模型，只解析整体进度所需的路径与真实字节数。
/// 保持为独立值类型，既避免把远端 JSON 结构泄漏进状态机，也便于用固定响应做契约测试。
struct LocalAIModelScopeFileListResponse: Decodable, Sendable {
    let code: Int
    let payload: Payload

    struct Payload: Decodable, Sendable {
        let files: [FileEntry]

        enum CodingKeys: String, CodingKey {
            case files = "Files"
        }
    }

    struct FileEntry: Decodable, Sendable {
        let path: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case path = "Path"
            case size = "Size"
        }
    }

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case payload = "Data"
    }

    /// 只返回 catalog 关心且体积有效的文件，目录或异常的 0 字节记录不参与总量。
    func fileSizes(wanted: Set<String>) -> [String: Int64] {
        guard code == 200 else { return [:] }
        return payload.files.reduce(into: [:]) { result, item in
            guard wanted.contains(item.path), item.size > 0 else { return }
            result[item.path] = item.size
        }
    }
}

@MainActor
@Observable
final class LocalAIModelManager {

    static let shared = LocalAIModelManager()

    /// 单模型下载状态（key = catalog entry id）。
    private(set) var installStates: [String: LocalAIInstallState] = [:]
    /// 已安装模型（磁盘 manifest 快照，启动 / 安装 / 删除时刷新）。
    private(set) var installedModels: [LocalAIInstalledModel] = []
    /// 是否正在同步内置 profile（避免重入）。
    private var isSyncingProfile = false
    /// 升级迁移完成前保留上次 profile，避免扫描共享目录为空时把已安装模型短暂清空。
    private var isSharedStoragePrepared = false

    private let downloader = LocalAIModelDownloader()
    /// catalog id -> 正在进行的下载 Task，供暂停/取消。
    private var runningInstalls: [String: Task<Void, Never>] = [:]
    /// 速度采样：0.5s 窗口取瞬时速度，0.7/0.3 EMA 平滑，避免条文字跳变。
    private struct SpeedSample {
        var lastTime: TimeInterval
        var lastBytes: Int64
        var speed: Double?
    }
    private var speedSamples: [String: SpeedSample] = [:]
    /// 暂停防抖代数：pause/install 各自 +1，使飞行中的进度回调立即过期，
    /// 避免暂停后按钮在「下载 / 进度」之间抖动直到底层取消完成。
    private var installGenerations: [String: Int] = [:]
    /// 清除全部是跨模型操作，不塞进单模型 task 字典，避免 pause 误取消一半状态。
    private var deleteAllTask: Task<Void, Never>?

    private init() {
        refreshInstalledModels()
        if !TestEnvironment.isRunning {
            refreshFromSharedStorage()
        }
    }

    // MARK: - 查询

    func installState(for entryID: String) -> LocalAIInstallState {
        // 加载阶段优先：manifest 已落盘（installedModels 快照已包含该模型），但容器
        // 仍在加载或加载失败——不能被「已安装」短路，否则 UI 看不到加载进度 / 失败。
        if let explicit = installStates[entryID] {
            switch explicit {
            case .loading, .loadFailed, .deleting, .deleteFailed:
                return explicit
            default:
                break
            }
        }
        if installedModels.contains(where: { $0.id == entryID }) {
            return .installed
        }
        return installStates[entryID] ?? .idle
    }

    func installedModel(id: String) -> LocalAIInstalledModel? {
        installedModels.first { $0.id == id }
    }

    /// 模型安装目录；未安装返回 nil。`LocalMLXClient` 解析模型名的入口。
    func installedDirectoryURL(entryID: String) -> URL? {
        guard let manifest = installedModel(id: entryID) else { return nil }
        guard let entry = LocalAIModelCatalog.entry(id: entryID) else { return nil }
        return try? LocalAIModelStorage.modelDirectory(entry: entry, revision: manifest.revision)
    }

    var modelsRootURL: URL? {
        try? LocalAIModelStorage.modelsRootURL()
    }

    var totalDiskUsage: Int64 {
        LocalAIModelStorage.totalDiskUsage()
    }

    /// 启动与 App 重新激活时刷新共享目录。另一渠道可能在本进程休眠期间完成安装
    /// 或删除，因此不能只依赖当前进程的安装回调。
    func refreshFromSharedStorage() {
        guard !TestEnvironment.isRunning else { return }
        Task {
            do {
                try await LocalAISharedModelCoordinator.shared.prepareSharedStorageIfNeeded()
                isSharedStoragePrepared = true
                refreshInstalledModels()
                syncBuiltInProfile()
            } catch {
                AppLog.ai.error(
                    "Prepare shared Local AI storage failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 单模型完整性检查：manifest 存在且声明的文件都在磁盘上。
    /// nil = 通过；否则返回用户可读的错误文案。
    private func integrityIssue(for entry: LocalAIModelCatalogEntry) -> String? {
        guard let manifest = installedModel(id: entry.id),
            let directory = installedDirectoryURL(entryID: entry.id)
        else {
            return String(
                format: String.l10n("settings.localai.error.modelNotInstalledFormat"),
                entry.displayName)
        }
        for file in manifest.files {
            let url = directory.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return String(
                    format: String.l10n("settings.localai.verify.missingFileFormat"),
                    entry.displayName, file.name)
            }
        }
        return nil
    }

    /// 加载已安装模型的 MLX 容器（下载完成链路 & 加载失败重试共用）。
    private func loadInstalledContainer(entry: LocalAIModelCatalogEntry) async throws {
        guard let directory = installedDirectoryURL(entryID: entry.id) else {
            throw LocalAIError.modelNotInstalled(entry.displayName)
        }
        try await LocalMLXRuntime.shared.preload(entry: entry, directory: directory)
    }

    /// 「重试加载」：loadFailed 状态下只重跑加载，不重新下载。
    func retryLoad(entry: LocalAIModelCatalogEntry) {
        guard TestEnvironment.isRunning == false else { return }
        guard case .loadFailed = installState(for: entry.id) else { return }
        guard runningInstalls[entry.id] == nil else { return }

        installStates[entry.id] = .loading
        installGenerations[entry.id, default: 0] += 1
        let generation = installGenerations[entry.id]!
        let task = Task {
            await self.runPreload(entry: entry, generation: generation)
        }
        runningInstalls[entry.id] = task
    }

    private func runPreload(entry: LocalAIModelCatalogEntry, generation: Int) async {
        do {
            try await loadInstalledContainer(entry: entry)
            guard installGenerations[entry.id] == generation else {
                runningInstalls[entry.id] = nil
                return
            }
            installStates[entry.id] = .installed
        } catch {
            guard installGenerations[entry.id] == generation else {
                runningInstalls[entry.id] = nil
                return
            }
            installStates[entry.id] = .loadFailed(message: error.localizedDescription)
        }
        runningInstalls[entry.id] = nil
    }

    /// 任务选择器视角：某能力下当前可用（已安装）的模型名列表。
    func installedModelNames(capability: AIModelCapability) -> [String] {
        LocalAIModelCatalog.entries
            .filter { $0.capability == capability }
            .filter { entry in installedModels.contains { $0.id == entry.id } }
            .map(\.displayName)
    }

    // MARK: - 安装 / 暂停 / 删除

    /// 下载并安装一个 catalog 模型（使用设置页当前选择的下载源）。
    /// 重复调用同 id 时忽略（UI 按钮已置灰，防御性兜底）。
    func install(entry: LocalAIModelCatalogEntry) {
        if TestEnvironment.isRunning { return }
        guard runningInstalls[entry.id] == nil else { return }
        guard !installState(for: entry.id).isInstalled else { return }

        let sourceKind = AppSettings.shared.localAIDownloadSource
        guard let source = entry.source(for: sourceKind) else {
            installStates[entry.id] = .failed(
                message: String.l10n("settings.localai.source.unavailable"))
            return
        }

        installStates[entry.id] = .preparing
        speedSamples[entry.id] = nil
        installGenerations[entry.id, default: 0] += 1
        let generation = installGenerations[entry.id]!
        // 强持有 self：manager 是进程级单例，安装期间不释放；weak 会让 Task 句柄变成 Void?。
        let task = Task {
            await self.runInstall(entry: entry, source: source, generation: generation)
        }
        runningInstalls[entry.id] = task
    }

    /// 暂停（取消当前下载）。`.part` 保留，下次 install 从断点续传。
    func pause(entryID: String) {
        installGenerations[entryID, default: 0] += 1
        runningInstalls[entryID]?.cancel()
        runningInstalls[entryID] = nil
        speedSamples[entryID] = nil
        if case .downloading = installStates[entryID] {
            installStates[entryID] = .idle
        } else if installStates[entryID] == .preparing {
            installStates[entryID] = .idle
        }
    }

    /// 公共任务等待现有状态机完成，不能把“已排队下载”当成“模型已可用”。
    func installAndWait(entry: LocalAIModelCatalogEntry) async throws {
        install(entry: entry)
        if let task = runningInstalls[entry.id] {
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        try Task.checkCancellation()
        switch installState(for: entry.id) {
        case .installed: return
        case .failed(let message), .loadFailed(let message):
            throw StarcatPublicCapabilityError(code: "MODEL_INSTALL_FAILED", message: message)
        default: throw CancellationError()
        }
    }

    /// 删除沿用卸载/跨渠道文件协调，完成后回读状态以暴露真实失败。
    func deleteAndWait(entryID: String) async throws {
        delete(entryID: entryID)
        if let task = runningInstalls[entryID] { await task.value }
        if case .deleteFailed(let message) = installState(for: entryID) {
            throw StarcatPublicCapabilityError(code: "MODEL_DELETE_FAILED", message: message)
        }
    }

    func delete(entryID: String) {
        pause(entryID: entryID)
        guard let manifest = installedModel(id: entryID),
            let entry = LocalAIModelCatalog.entry(id: entryID)
        else { return }
        installStates[entryID] = .deleting
        let task = Task {
            do {
                await LocalMLXRuntime.shared.unload(
                    types: [entry.type],
                    reason: "model_deleted")
                let directory = try LocalAIModelStorage.modelDirectory(
                    entry: entry,
                    revision: manifest.revision)
                try await LocalAISharedModelCoordinator.shared.removeModel(at: directory)
                isSharedStoragePrepared = true
                refreshInstalledModels()
                installStates[entryID] = .idle
                syncBuiltInProfile()
            } catch is CancellationError {
                installStates[entryID] = .installed
            } catch {
                installStates[entryID] = .deleteFailed(message: error.localizedDescription)
            }
            runningInstalls[entryID] = nil
        }
        runningInstalls[entryID] = task
    }

    /// 删除全部本地模型（设置页危险操作）。
    func deleteAll() {
        guard deleteAllTask == nil else { return }
        for entry in LocalAIModelCatalog.entries {
            pause(entryID: entry.id)
        }
        let entryIDs = installedModels.map(\.id)
        for entryID in entryIDs {
            installStates[entryID] = .deleting
        }
        deleteAllTask = Task {
            do {
                await LocalMLXRuntime.shared.unloadAll(reason: "all_models_deleted")
                try await LocalAISharedModelCoordinator.shared.removeAllModels()
                isSharedStoragePrepared = true
                refreshInstalledModels()
                for entryID in entryIDs { installStates[entryID] = .idle }
                syncBuiltInProfile()
            } catch {
                for entryID in entryIDs {
                    installStates[entryID] = .deleteFailed(message: error.localizedDescription)
                }
            }
            deleteAllTask = nil
        }
    }

    /// 下载源变化时先取消本进程全部下载，再在全局独占锁内清理断点文件。
    func cleanPartialDownloadsForSourceChange() {
        for entry in LocalAIModelCatalog.entries {
            pause(entryID: entry.id)
        }
        Task {
            do {
                try await LocalAISharedModelCoordinator.shared.cleanPartialFiles()
            } catch {
                AppLog.ai.error(
                    "Clean shared Local AI partial files failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 内部安装流程

    private func runInstall(
        entry: LocalAIModelCatalogEntry, source: LocalAIModelSource, generation: Int
    ) async {
        var modelWriteLease: LocalAIModelAccessLease?
        // 所有暂停 / 代数失效的提前 return 都必须释放跨进程独占锁。
        defer { modelWriteLease?.release() }
        do {
            try await LocalAISharedModelCoordinator.shared.prepareSharedStorageIfNeeded()
            isSharedStoragePrepared = true
            let revision = try await resolveRevision(for: source)
            let directory = try LocalAIModelStorage.modelDirectory(
                entry: entry, revision: revision)
            modelWriteLease = try await LocalAISharedModelCoordinator.shared
                .acquireModelWrite(at: directory)

            let existingManifest = try? LocalAIModelStorage.loadManifest(from: directory)
            let isAlreadyInstalled = existingManifest.map {
                LocalAIModelStorage.isInstallationValid(
                    manifest: $0,
                    directory: directory,
                    verifyHashes: false)
            } ?? false

            if !isAlreadyInstalled {
                // manifest 已存在但内容不完整时不能继续拼接旧文件；无 manifest 的目录
                // 则保留 `.part`，让正常暂停 / 续传继续生效。
                if FileManager.default.fileExists(
                    atPath: LocalAIModelStorage.manifestURL(in: directory).path)
                {
                    try FileManager.default.removeItem(at: directory)
                }

                var records: [LocalAIFileRecord] = []
                let optionalFiles = Set(
                    entry.files.filter { !$0.isRequired }.map(\.name))

                // 下载前从当前源取完整文件清单。只要所有必需文件都有大小，总量就是远端
                // 真值；元数据请求失败才回退 catalog 预估，但已下载字节始终来自落盘回调，
                // 禁止再把预估体积按文件数均分（KB 配置文件会被虚增成数百 MB）。
                let fileSizes = await resolveFileSizes(
                    for: entry, source: source, revision: revision)
                let knownTotal = entry.files.compactMap { fileSizes[$0.name] }.reduce(0, +)
                let hasCompleteSizePlan = entry.files
                    .filter(\.isRequired)
                    .allSatisfy { fileSizes[$0.name] != nil }
                let totalBytes = hasCompleteSizePlan && knownTotal > 0
                    ? knownTotal
                    : entry.estimatedDownloadSize
                var doneBytesBefore: Int64 = 0

                for file in entry.files {
                    if Task.isCancelled {
                        modelWriteLease?.release()
                        modelWriteLease = nil
                        installStates[entry.id] = .idle
                        runningInstalls[entry.id] = nil
                        return
                    }
                    // 快照进 @Sendable 闭包：循环变量 doneBytesBefore 在闭包存活期内会被改写，
                    // 直接捕获 var 在严格并发下不合法。
                    let doneBeforeSnapshot = doneBytesBefore
                    do {
                        let record = try await downloadOne(
                            entry: entry, source: source, revision: revision, file: file.name,
                            directory: directory,
                            onFileProgress: { [weak self] fileProgress in
                                // 整体进度 = 已完成文件真实字节 + 当前文件真实落盘字节；状态机
                                // 与速度采样都在 MainActor 上，统一 hop 过去。
                                Task { @MainActor [weak self] in
                                    guard let self, self.installGenerations[entry.id] == generation else { return }
                                    let completed = doneBeforeSnapshot + fileProgress.completedBytes
                                    let speed = self.updateSpeedSampler(
                                        entryID: entry.id, completedBytes: completed)
                                    let rawProgress = totalBytes > 0
                                        ? Double(completed) / Double(totalBytes)
                                        : 0
                                    self.installStates[entry.id] = .downloading(
                                        // 元数据失败时 catalog 只是估值，下载阶段最多显示 99%，
                                        // 避免真实文件略大于估值时尚未完成就提前走满。
                                        progress: min(hasCompleteSizePlan ? 1 : 0.99, rawProgress),
                                        completedBytes: completed,
                                        totalBytes: totalBytes,
                                        speedBytesPerSecond: speed)
                                }
                            })
                        records.append(record)
                        guard installGenerations[entry.id] == generation else {
                            runningInstalls[entry.id] = nil
                            return
                        }
                        doneBytesBefore += record.sizeBytes
                    } catch let error as LocalAIDownloadError {
                        if error == .cancelled {
                            installStates[entry.id] = .idle
                            speedSamples[entry.id] = nil
                            runningInstalls[entry.id] = nil
                            return
                        }
                        // 可选文件 404 / 不存在时跳过（不同 mlx-community 转换仓库文件集不一致）。
                        if optionalFiles.contains(file.name), isNotFound(error) {
                            continue
                        }
                        throw error
                    }
                }
                speedSamples[entry.id] = nil

                let manifest = LocalAIInstalledModel(
                    id: entry.id,
                    displayName: entry.displayName,
                    type: entry.type,
                    revision: revision,
                    installedAt: Date(),
                    sourceKind: source.kind,
                    files: records,
                    embeddingDimension: entry.embeddingDimension,
                    totalBytes: records.reduce(0) { $0 + $1.sizeBytes })
                try LocalAIModelStorage.save(manifest, in: directory)
            }

            // preload 会取得共享读锁；必须先释放下载独占锁，避免同进程自锁。
            modelWriteLease?.release()
            modelWriteLease = nil

            refreshInstalledModels()
            syncBuiltInProfile()

            // ② 检查：manifest 与磁盘文件对账（下载时已流式计算 SHA256，这里做廉价存在性校验）。
            if let issue = integrityIssue(for: entry) {
                installStates[entry.id] = .failed(message: issue)
                runningInstalls[entry.id] = nil
                return
            }
            // ③ 加载：预热容器，首次真实调用零等待；失败进入 loadFailed（可单独重试）。
            installStates[entry.id] = .loading
            do {
                try await loadInstalledContainer(entry: entry)
                guard installGenerations[entry.id] == generation else {
                    runningInstalls[entry.id] = nil
                    return
                }
                installStates[entry.id] = .installed
            } catch {
                guard installGenerations[entry.id] == generation else {
                    runningInstalls[entry.id] = nil
                    return
                }
                installStates[entry.id] = .loadFailed(message: error.localizedDescription)
            }
        } catch is CancellationError {
            modelWriteLease?.release()
            installStates[entry.id] = .idle
        } catch {
            modelWriteLease?.release()
            installStates[entry.id] = .failed(message: error.localizedDescription)
        }
        runningInstalls[entry.id] = nil
    }

    private func downloadOne(
        entry: LocalAIModelCatalogEntry,
        source: LocalAIModelSource,
        revision: String,
        file: String,
        directory: URL,
        onFileProgress: @escaping @Sendable (LocalAIDownloadProgress) -> Void
    ) async throws -> LocalAIFileRecord {
        let remoteURL: URL
        switch source.kind {
        case .huggingFace:
            guard let url = URL(string: "https://huggingface.co/\(source.repo)/resolve/\(revision)/\(file)"
            ) else {
                throw LocalAIDownloadError.invalidURL(file)
            }
            remoteURL = url
        case .modelScope:
            // ModelScope 镜像为社区同步，固定 master 快照；revision 记进 manifest 可追溯。
            guard let url = URL(string: "https://modelscope.cn/models/\(source.repo)/resolve/master/\(file)"
            ) else {
                throw LocalAIDownloadError.invalidURL(file)
            }
            remoteURL = url
        }
        let result = try await downloader.downloadFile(
            remoteURL: remoteURL,
            fileName: file,
            sourceKind: source.kind,
            into: directory,
            expectedTotalBytes: entry.estimatedDownloadSize,
            onProgress: { progress in
                onFileProgress(progress)
            })
        return LocalAIFileRecord(
            name: result.name, sha256: result.sha256, sizeBytes: result.sizeBytes)
    }

    /// 解析远端 revision：固定值直接用；HF 查 API 取当前 commit SHA（记录进 manifest
    /// 可追溯）；ModelScope 镜像为社区同步，固定 master 快照。
    private func resolveRevision(for source: LocalAIModelSource) async throws -> String {
        if let revision = source.revision { return revision }
        switch source.kind {
        case .modelScope:
            return "master"
        case .huggingFace:
            guard let url = URL(string: "https://huggingface.co/api/models/\(source.repo)") else {
                throw LocalAIDownloadError.invalidURL(source.repo)
            }
            var request = URLRequest(url: url)
            request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw LocalAIDownloadError.invalidURL(source.repo)
            }
            struct HFModelInfo: Decodable { let sha: String }
            return try JSONDecoder().decode(HFModelInfo.self, from: data).sha
        }
    }

    /// EMA 速度采样。0.5s 内的重复回调沿用上次速度，避免文字频繁跳变。
    private func updateSpeedSampler(entryID: String, completedBytes: Int64) -> Double? {
        let now = Date().timeIntervalSinceReferenceDate
        if var sample = speedSamples[entryID] {
            let dt = now - sample.lastTime
            guard dt >= 0.5 else { return sample.speed }
            let instantaneous = Double(completedBytes - sample.lastBytes) / dt
            sample.speed = sample.speed == nil
                ? instantaneous
                : sample.speed! * 0.7 + instantaneous * 0.3
            sample.lastTime = now
            sample.lastBytes = completedBytes
            speedSamples[entryID] = sample
            return sample.speed
        }
        speedSamples[entryID] = SpeedSample(lastTime: now, lastBytes: completedBytes, speed: nil)
        return nil
    }

    /// 从当前下载源读取文件清单：HF 的 LFS 文件取 `lfs.size`，ModelScope 取
    /// `/repo/files` 的 `Size`。失败返回空字典并回退 catalog 总体积，不阻断下载。
    private func resolveFileSizes(
        for entry: LocalAIModelCatalogEntry, source: LocalAIModelSource, revision: String
    ) async -> [String: Int64] {
        let url: URL?
        switch source.kind {
        case .huggingFace:
            url = URL(string:
                "https://huggingface.co/api/models/\(source.repo)/tree/\(revision)?recursive=true")
        case .modelScope:
            var components = URLComponents(
                string: "https://modelscope.cn/api/v1/models/\(source.repo)/repo/files")
            components?.queryItems = [
                URLQueryItem(name: "Revision", value: revision),
                URLQueryItem(name: "Recursive", value: "true"),
            ]
            url = components?.url
        }
        guard let url else { return [:] }
        var request = URLRequest(url: url)
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return [:]
            }
            let wanted = Set(entry.files.map(\.name))
            switch source.kind {
            case .huggingFace:
                struct TreeEntry: Decodable {
                    let path: String
                    let size: Int64?
                    let lfs: LFSInfo?
                    struct LFSInfo: Decodable { let size: Int64? }
                }
                let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
                var sizes: [String: Int64] = [:]
                for item in entries where wanted.contains(item.path) {
                    if let size = item.lfs?.size ?? item.size, size > 0 {
                        sizes[item.path] = size
                    }
                }
                return sizes
            case .modelScope:
                let response = try JSONDecoder().decode(
                    LocalAIModelScopeFileListResponse.self, from: data)
                return response.fileSizes(wanted: wanted)
            }
        } catch {
            AppLog.ai.debug(
                "LocalAI file size lookup failed (fallback to estimate): \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func isNotFound(_ error: LocalAIDownloadError) -> Bool {
        if case .httpStatus(let code) = error { return code == 404 }
        return false
    }

    private func refreshInstalledModels() {
        installedModels = (try? LocalAIModelStorage.listInstalled()) ?? []
    }

    // MARK: - 内置 profile 同步

    /// 把安装状态写进内置 profile。App 启动与每次安装 / 删除后调用。
    ///
    /// - 无条件 seed（Apple Silicon 上）：内置 profile 必须始终出现在 AI 设置的服务商
    ///   列表里，用户才能选中它并进入模型下载区；没有模型时 `lastTestStatus = .notTested`
    ///   （未验证 → 不会出现在任务模型下拉，也不会被 selection 解析放行）。
    /// - `lastTestStatus` 只承担「本地 provider 已验证」语义：有任一已安装模型即
    ///   `.success(modelCount:)`；细粒度的 capability 匹配仍由 `resolveChatSelection` /
    ///   `resolveEmbeddingSelection` 按 `profile.models` 校验兜底。
    func syncBuiltInProfile() {
        guard !TestEnvironment.isRunning else { return }
        guard isSharedStoragePrepared else { return }
        guard !isSyncingProfile else { return }
        isSyncingProfile = true
        defer { isSyncingProfile = false }

        guard LocalAIHardwareSupport.isLocalAIAvailable else {
            AppLog.ai.info("syncBuiltInProfile: skip, hardware unsupported")
            return
        }

        let settings = AppSettings.shared
        var profiles = settings.aiProviderProfiles
        let index = profiles.firstIndex { $0.id == LocalAIModelCatalog.builtInProfileID }
        let descriptors = Self.installedModelDescriptors(
            installedModels: installedModels,
            previousModels: index.map { profiles[$0].models } ?? [])

        if let index {
            var profile = profiles[index]
            guard profile.provider == .localAI else { return }
            profile.models = descriptors
            profile.lastTestStatus = descriptors.isEmpty
                ? .notTested
                : .success(modelCount: descriptors.count)
            profiles[index] = profile
        } else {
            let profile = AIProviderProfile(
                id: LocalAIModelCatalog.builtInProfileID,
                provider: .localAI,
                models: descriptors,
                lastTestStatus: descriptors.isEmpty
                    ? .notTested
                    : .success(modelCount: descriptors.count))
            profiles.append(profile)
        }
        settings.aiProviderProfiles = profiles
    }

    /// 已安装模型 → 内置 profile 的 AIModelDescriptor 列表。
    ///
    /// name 用 catalog 稳定名（用户在任务配置里看到的名字）；revision 由
    /// `LocalMLXClient` 经 manager 解析，用户不感知。
    /// 安装清单只更新可用模型集合；参数覆盖与禁用状态属于用户配置，不能在同步时重置。
    static func installedModelDescriptors(
        installedModels: [LocalAIInstalledModel], previousModels: [AIModelDescriptor]
    ) -> [AIModelDescriptor] {
        let catalogByID = Dictionary(
            uniqueKeysWithValues: LocalAIModelCatalog.entries.map { ($0.id, $0) })
        return installedModels.compactMap { manifest in
            guard let entry = catalogByID[manifest.id] else { return nil }
            let previous = previousModels.first { $0.name == entry.displayName }
            return AIModelDescriptor(
                id: previous?.id,
                providerID: LocalAIModelCatalog.builtInProfileID,
                name: entry.displayName,
                ownedBy: "Starcat Local AI",
                capability: entry.capability,
                isEnabled: previous?.isEnabled ?? true,
                parameters: previous?.parameters)
        }
    }
}
