//
//  RuntimeDownloadManager.swift
//  Starcat
//
//  进程级 Runtime 安装会话：设置页与状态面板观察同一状态，离开页面不取消。
//  下载、校验及安装仍由原 installer 负责，只有成功且未取消才提交配置。
//

import Foundation
import Observation

/// 只保存本进程的安装结果；正常完成不再计入后台任务，不建立持久任务历史。
enum RuntimeDownloadState: Equatable {
    case idle
    case installing(progress: Double?)
    case configuring
    case cancelling
    case completed(version: String)
    case failed(message: String)

    var isInstalling: Bool {
        switch self {
        case .installing, .configuring, .cancelling: true
        default: false
        }
    }
}

/// 按 Runtime 去重并持有任务；配置阶段不接受取消，避免将已经提交的路径伪装为回滚。
@MainActor
@Observable
final class RuntimeDownloadManager {
    typealias Install = @MainActor (
        DownloadableRuntime, @escaping @Sendable (Double?) -> Void
    ) async throws -> RuntimeDownloadInstallation
    typealias Configure = @MainActor (RuntimeDownloadInstallation) async throws -> Void

    static let shared = RuntimeDownloadManager()

    private(set) var states: [DownloadableRuntime: RuntimeDownloadState] = [:]
    @ObservationIgnored private var jobs: [DownloadableRuntime: Job] = [:]
    private let install: Install
    private let configure: Configure

    /// 身份阻止取消前排队的进度回调覆盖下一轮安装；任务保留至底层退出才能重启。
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
    }

    init(
        install: @escaping Install = { runtime, progress in
            try await RuntimeDownloadInstaller.shared.install(runtime, progress: progress)
        },
        configure: @escaping Configure = { installation in
            try await RuntimeDownloadManager.configureInstallation(installation)
        }
    ) {
        self.install = install
        self.configure = configure
    }

    func state(for runtime: DownloadableRuntime) -> RuntimeDownloadState {
        states[runtime] ?? .idle
    }

    /// 确认仍由设置页处理；此处只接收已确认的安装请求，重复请求复用当前会话。
    func start(_ runtime: DownloadableRuntime) {
        guard jobs[runtime] == nil else { return }
        let id = UUID()
        states[runtime] = .installing(progress: nil)
        let task = Task {
            defer { jobs[runtime] = nil }
            do {
                let installation = try await install(runtime) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.jobs[runtime]?.id == id,
                              case .installing = self.state(for: runtime) else { return }
                        self.states[runtime] = .installing(progress: progress)
                    }
                }
                try Task.checkCancellation()
                states[runtime] = .configuring
                try await configure(installation)
                states[runtime] = .completed(version: installation.reportedVersion)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    states[runtime] = .idle
                } else {
                    states[runtime] = .failed(message: error.localizedDescription)
                }
            }
        }
        jobs[runtime] = Job(id: id, task: task)
    }

    /// 取消只作用于所选安装；等待底层清理完成期间仍展示状态，不能重新下载同一 Runtime。
    func cancel(_ runtime: DownloadableRuntime) {
        guard case .installing = state(for: runtime), let job = jobs[runtime] else { return }
        states[runtime] = .cancelling
        job.task.cancel()
    }

    /// 配置不依赖已销毁视图的 Binding。保留 resolver 的二次校验与成功后写入约束。
    static func configureInstallation(_ installation: RuntimeDownloadInstallation) async throws {
        switch installation.runtime {
        case .codex:
            UserDefaults.standard.set(installation.directory.path, forKey: ExternalAgentRuntimePreferences.codexExecutablePathKey)
        case .deepSeek:
            UserDefaults.standard.set(installation.executable.path, forKey: ExternalAgentRuntimePreferences.deepSeekExecutablePathKey)
            UserDefaults.standard.set(installation.configuration?.path ?? "", forKey: ExternalAgentRuntimePreferences.deepSeekCordisConfigPathKey)
        case .codebaseMemory:
            _ = try await CodebaseMemoryBinaryResolver().selectExecutable(installation.executable)
        }
    }
}
