//
//  CodeFlowViewModel.swift
//  Starcat
//
//  驱动下载 ZIP -> 生成自动分析页面 -> 默认浏览器打开的单仓库流程。
//

import AppKit
import Foundation

@MainActor
@Observable
final class CodeFlowViewModel {
    enum State: Equatable {
        case idle
        case downloading
        case preparing
        case opening
        case succeeded
        case failed(message: String)
    }

    private(set) var state: State = .idle
    private(set) var log = ""

    private let repo: Repo
    private let runner: CodeFlowRunner
    private var task: Task<Void, Never>?

    init(repo: Repo, runner: CodeFlowRunner = CodeFlowRunner()) {
        self.repo = repo
        self.runner = runner
    }

    func start() {
        task?.cancel()
        log = ""
        task = Task {
            do {
                state = .downloading
                let (archiveURL, wasDownloaded) = try await runner.archiveIfNeeded(repo: repo)
                append(wasDownloaded
                    ? "ZIP 下载完成：\(archiveURL.path)"
                    : "本地 ZIP 已存在，跳过下载：\(archiveURL.path)")

                try Task.checkCancellation()
                state = .preparing
                let pageURL = try runner.makeVisualizationPage(
                    archiveURL: archiveURL,
                    owner: repo.owner,
                    name: repo.name
                )

                try Task.checkCancellation()
                state = .opening
                guard NSWorkspace.shared.open(pageURL) else {
                    throw NSError(
                        domain: "Starcat.CodeFlow",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "默认浏览器无法打开 CodeFlow 页面。"]
                    )
                }
                append("已打开：\(pageURL.path)")
                state = .succeeded
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private func append(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !log.isEmpty { log += "\n\n" }
        log += value
    }
}
