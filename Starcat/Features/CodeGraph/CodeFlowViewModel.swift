//
//  CodeFlowViewModel.swift
//  Starcat
//
//  驱动 clone -> 生成自动分析页面 -> 默认浏览器打开的单仓库流程。
//

import AppKit
import Foundation

@MainActor
@Observable
final class CodeFlowViewModel {
    enum State: Equatable {
        case idle
        case cloning
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
                state = .cloning
                let (repositoryURL, cloneResult) = try await runner.cloneIfNeeded(repo: repo)
                if let cloneResult { append("$ \(cloneResult.commandDescription)\n\(cloneResult.stdout)\n\(cloneResult.stderr)") }
                else { append("本地仓库已存在，跳过 clone：\(repositoryURL.path)") }

                try Task.checkCancellation()
                state = .preparing
                let pageURL = try runner.makeVisualizationPage(
                    repositoryURL: repositoryURL,
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
