//
//  RuntimeDownloadManagerTests.swift
//  StarcatTests
//
//  使用可挂起的假安装验证进程级任务所有权、去重与取消边界，不下载程序或写真实配置。
//

import Foundation
import Testing
@testable import Starcat

/// 生命周期验证独立于 SwiftUI 页面；测试释放入口闭包后，管理器仍必须完成配置。
@MainActor
struct RuntimeDownloadManagerTests {
    @Test("安装由共享会话持有，重复点击不会启动第二轮")
    func managerOwnsInstallation() async throws {
        let gate = RuntimeInstallGate()
        var installCount = 0
        var configured: [DownloadableRuntime] = []
        let manager = RuntimeDownloadManager(install: { runtime, progress in
            installCount += 1
            progress(0.5)
            await gate.suspend()
            return Self.installation(runtime)
        }, configure: { configured.append($0.runtime) })
        var entryPoint: (() -> Void)? = { manager.start(.codex) }
        entryPoint?()
        await gate.waitForSuspension()
        entryPoint = nil
        manager.start(.codex)
        #expect(installCount == 1)
        #expect(manager.state(for: .codex).isInstalling)
        gate.resume()
        try await settle(manager, runtime: .codex)
        #expect(configured == [.codex])
        #expect(manager.state(for: .codex) == .completed(version: "test-version"))
    }

    @Test("取消等待底层退出，不提交配置，也不允许清理期间重启")
    func cancellationDoesNotConfigure() async throws {
        let gate = RuntimeInstallGate()
        var installs = 0
        var configurations = 0
        let manager = RuntimeDownloadManager(install: { runtime, _ in
            installs += 1
            await gate.suspend()
            // 模拟底层已经返回安装目录，取消检查仍必须阻止配置写入。
            return Self.installation(runtime)
        }, configure: { _ in configurations += 1 })
        manager.start(.codex)
        await gate.waitForSuspension()
        manager.cancel(.codex)
        manager.start(.codex)
        #expect(installs == 1)
        #expect(manager.state(for: .codex) == .cancelling)
        gate.resume()
        try await settle(manager, runtime: .codex)
        #expect(configurations == 0)
        #expect(manager.state(for: .codex) == .idle)
    }

    @Test("配置提交阶段不接受停止，不能宣称已提交结果被回滚")
    func configurationCannotBeCancelled() async throws {
        let gate = RuntimeInstallGate()
        let manager = RuntimeDownloadManager(install: { runtime, _ in Self.installation(runtime) },
                                            configure: { _ in await gate.suspend() })
        manager.start(.codex)
        await gate.waitForSuspension()
        manager.cancel(.codex)
        #expect(manager.state(for: .codex) == .configuring)
        gate.resume()
        try await settle(manager, runtime: .codex)
        #expect(manager.state(for: .codex) == .completed(version: "test-version"))
    }

    @Test("不同 Runtime 并行且取消互不影响")
    func runtimesAreIndependent() async throws {
        let codex = RuntimeInstallGate()
        let memory = RuntimeInstallGate()
        var configured: [DownloadableRuntime] = []
        let manager = RuntimeDownloadManager(install: { runtime, _ in
            await (runtime == .codex ? codex : memory).suspend()
            return Self.installation(runtime)
        }, configure: { configured.append($0.runtime) })
        manager.start(.codex)
        manager.start(.codebaseMemory)
        await codex.waitForSuspension()
        await memory.waitForSuspension()
        manager.cancel(.codex)
        codex.resume()
        memory.resume()
        try await settle(manager, runtime: .codex)
        try await settle(manager, runtime: .codebaseMemory)
        #expect(configured == [.codebaseMemory])
    }

    @Test("安装或配置失败保留错误，重试复用同一 Runtime 身份")
    func failuresCanBeRetried() async throws {
        var shouldFail = true
        var configurations = 0
        let manager = RuntimeDownloadManager(install: { runtime, _ in
            if shouldFail { throw URLError(.cannotConnectToHost) }
            return Self.installation(runtime)
        }, configure: { _ in
            configurations += 1
            throw RuntimeDownloadError.checksum
        })
        manager.start(.codex)
        try await settle(manager, runtime: .codex)
        guard case .failed = manager.state(for: .codex) else {
            Issue.record("下载失败必须可见")
            return
        }
        #expect(configurations == 0)
        shouldFail = false
        manager.start(.codex)
        try await settle(manager, runtime: .codex)
        guard case .failed = manager.state(for: .codex) else {
            Issue.record("配置失败必须可见")
            return
        }
        #expect(configurations == 1)
    }

    private static func installation(_ runtime: DownloadableRuntime) -> RuntimeDownloadInstallation {
        RuntimeDownloadInstallation(
            runtime: runtime, directory: URL(fileURLWithPath: "/tmp/runtime-test"),
            executable: URL(fileURLWithPath: "/tmp/runtime-test/bin"),
            configuration: URL(fileURLWithPath: "/tmp/runtime-test/config"), reportedVersion: "test-version"
        )
    }

    /// 有界等待最终状态，避免调度时序测试在失败时永久挂起。
    private func settle(_ manager: RuntimeDownloadManager, runtime: DownloadableRuntime) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while manager.state(for: runtime).isInstalling, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!manager.state(for: runtime).isInstalling)
    }
}

/// 显式握手代替固定 sleep，保证取消发生在假安装挂起之后。
@MainActor
private final class RuntimeInstallGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitForSuspension() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
