//
//  SettingsConnectionTest.swift
//  Starcat
//
//  设置页连接测试的会话状态。每次编辑废弃旧请求，只有当前测试成功后才允许保存。
//

import Foundation
import Observation

/// 每个连接独立持有一个实例；请求可以继续结束，但过期请求没有保存或发布结果的资格。
@MainActor
@Observable
final class SettingsConnectionTest<Output> {
    private(set) var result: Output?
    private(set) var errorMessage: String?
    private(set) var isTesting = false
    private(set) var isSaving = false
    private var revision = UUID()

    /// 输入变化立即清除旧反馈，同时允许新输入开始测试，不等待旧网络请求结束。
    func invalidate() {
        revision = UUID()
        result = nil
        errorMessage = nil
        isTesting = false
    }

    /// 显式重置无需网络验证，但必须与保存互斥，且立即废弃重置前的探测结果。
    @discardableResult
    func reset(using action: @MainActor () async throws -> Void) async -> Bool {
        guard !isSaving else { return false }
        invalidate()
        isSaving = true
        defer { isSaving = false }
        do {
            try await action()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// probe 不得产生持久化副作用。保存期间调用方禁用编辑，避免提交被拆成两个版本。
    func run(
        probe: @MainActor () async throws -> Output,
        save: @MainActor (Output) async throws -> Void = { _ in }
    ) async {
        guard !isTesting, !isSaving else { return }
        let request = UUID()
        revision = request
        isTesting = true
        result = nil
        errorMessage = nil
        defer {
            if revision == request { isTesting = false }
        }
        do {
            let output = try await probe()
            guard revision == request, !Task.isCancelled else { return }
            isSaving = true
            defer { isSaving = false }
            try await save(output)
            guard revision == request, !Task.isCancelled else { return }
            result = output
        } catch {
            guard revision == request, !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
