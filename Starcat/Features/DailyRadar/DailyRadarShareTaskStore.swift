//
//  DailyRadarShareTaskStore.swift
//  Starcat
//
//  不可变报告快照的会话任务：按内容三元组去重，失败重试仍使用最初的报告。
//

import Foundation
import CoreGraphics
import Observation

/// 最小依赖让任务生命周期与失败行为可离线验证，不额外构造 AppDependencies。
@MainActor
struct DailyRadarShareOperations {
    let renderCover: @MainActor (DailyRadarReport) throws -> (image: CGImage, png: Data)
    let createShare: @MainActor (DailyRadarShareRequest, Data) async throws -> DailyRadarShareResponse
}

/// 一次生成尝试；新 taskID 区分重试，报告身份用于恢复 Sheet。
struct DailyRadarShareJob {
    enum State: Equatable {
        case creating
        case success(DailyRadarShareResponse)
        case failure(DailyRadarShareError)

        var isRunning: Bool {
            if case .creating = self { return true }
            return false
        }
    }

    let taskID = UUID()
    let report: DailyRadarReport
    var state: State
    var coverImage: CGImage?
}

/// MainActor 统一发布 UI 状态；任务独立于 Sheet，关闭弹层后仍可恢复结果。
@MainActor
@Observable
final class DailyRadarShareTaskStore {
    private(set) var jobs: [String: DailyRadarShareJob] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func isRunning(identity: String) -> Bool {
        jobs[identity]?.state.isRunning == true
    }

    /// 已有任务只恢复结果；不能因重复点击多次渲染或重复上传。
    func start(report: DailyRadarReport, operations: DailyRadarShareOperations) {
        guard jobs[report.contentIdentity] == nil else { return }
        launch(report: report, operations: operations)
    }

    /// 重试绑定原始快照；生成中与成功态不接受重试。
    func retry(identity: String, operations: DailyRadarShareOperations) {
        guard let job = jobs[identity], case .failure = job.state else { return }
        launch(report: job.report, operations: operations)
    }

    private func launch(report: DailyRadarReport, operations: DailyRadarShareOperations) {
        let identity = report.contentIdentity
        let job = DailyRadarShareJob(report: report, state: .creating)
        jobs[identity] = job
        tasks[identity] = Task { @MainActor [weak self] in
            await self?.execute(report: report, taskID: job.taskID, operations: operations)
        }
    }

    /// 所有 await 后都核对任务身份；上一尝试的完成不能覆盖下一次重试。
    private func execute(report: DailyRadarReport, taskID: UUID, operations: DailyRadarShareOperations) async {
        let identity = report.contentIdentity
        defer {
            if jobs[identity]?.taskID == taskID { tasks[identity] = nil }
        }
        do {
            let request = try DailyRadarShareRequest(detail: report)
            let cover = try operations.renderCover(report)
            guard jobs[identity]?.taskID == taskID else { return }
            jobs[identity]?.coverImage = cover.image
            let response = try await operations.createShare(request, cover.png)
            update(identity: identity, taskID: taskID, state: .success(response))
        } catch {
            update(identity: identity, taskID: taskID, state: .failure(DailyRadarShareError.from(error)))
        }
    }

    private func update(identity: String, taskID: UUID, state: DailyRadarShareJob.State) {
        guard jobs[identity]?.taskID == taskID else { return }
        jobs[identity]?.state = state
    }
}
