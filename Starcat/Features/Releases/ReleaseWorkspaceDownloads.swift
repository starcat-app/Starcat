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
        case saved(URL)
        case failed(String)
    }

    typealias Transfer = @MainActor (ReleaseAsset, @escaping @Sendable (Double) -> Void) async -> ReleaseAssetDownloadCoordinator.Outcome
    private let transfer: Transfer
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
        let previous = states[id]
        if case .running = previous { return }
        states[id] = .running(0)
        let outcome = await transfer(asset) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .running(let current) = self.states[id] else { return }
                self.states[id] = .running(max(current, min(1, fraction)))
            }
        }
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
}
