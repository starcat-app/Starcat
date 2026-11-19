//
//  ReleaseWorkspaceDownloads.swift
//  Starcat
//
//  下载状态属于工作区而不是可消失的文件行；筛选或切换版本不应中断传输或丢失结果。
//

import Foundation
import Observation

@MainActor @Observable
final class ReleaseWorkspaceDownloads {
    enum State: Equatable {
        case running(Double)
        case cancelling
        case saved(URL)
        case failed(String)
    }

    typealias Transfer = @MainActor (ReleaseAsset, @escaping @Sendable (Double) -> Void) async -> ReleaseAssetDownloadCoordinator.Outcome
    private let transfer: Transfer
    @ObservationIgnored private var transfers: [
        Int64: (attempt: UUID, task: Task<ReleaseAssetDownloadCoordinator.Outcome, Never>)
    ] = [:]
    private(set) var states: [Int64: State] = [:]
    var message: String?
    var fileURL: URL?

    init(transfer: @escaping Transfer = { asset, progress in
        await ReleaseAssetDownloadCoordinator.download(asset: asset, onProgress: progress)
    }) {
        self.transfer = transfer
    }

    /// 先占住文件的保存面板和传输；取消重新保存时仍保留之前真实的 Finder 位置。
    func start(_ asset: ReleaseAsset) async {
        let id = asset.id
        guard transfers[id] == nil else { return }
        let previous = states[id]
        let attempt = UUID()
        states[id] = .running(0)
        let task = Task<ReleaseAssetDownloadCoordinator.Outcome, Never> { [weak self, transfer] in
            guard !Task.isCancelled else { return .cancelled }
            return await transfer(asset) { [weak self] fraction in
                Task { @MainActor in
                    // 进度跨队列到达，上一轮的回调不能覆盖重试后的新进度。
                    guard let self, self.transfers[id]?.attempt == attempt,
                          case .running(let current) = self.states[id] else { return }
                    self.states[id] = .running(max(current, min(1, fraction)))
                }
            }
        }
        transfers[id] = (attempt, task)
        let outcome = await task.value
        transfers[id] = nil
        switch outcome {
        case .cancelled:
            states[id] = previous
        case .failed(let reason):
            states[id] = .failed(reason)
            fileURL = nil
            message = reason
        case .saved(let destination):
            states[id] = .saved(destination)
            let payload = ReleaseAssetDownloadToastSupport.successMessage(forFileURL: destination)
            fileURL = payload.fileURL
            message = payload.message
        }
    }

    /// 等传输实际退出才恢复原按钮，期间不允许再次打开同一文件的保存面板。
    func cancel(_ id: Int64) {
        guard let transfer = transfers[id], case .running = states[id] else { return }
        states[id] = .cancelling
        transfer.task.cancel()
    }
}
