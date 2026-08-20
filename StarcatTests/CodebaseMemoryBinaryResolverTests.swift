//
//  CodebaseMemoryBinaryResolverTests.swift
//  StarcatTests
//
//  固化 #58 的渠道隔离、Direct 路径优先级与版本探测超时。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CodebaseMemoryBinaryResolver")
struct CodebaseMemoryBinaryResolverTests {

    @Test("Direct 优先使用用户选择路径")
    func directPrefersUserSelection() async throws {
        try await withFixture { fixture in
            let selected = try fixture.copyExecutable(named: "selected")
            _ = try fixture.copyExecutable(
                named: "codebase-memory-mcp",
                directory: fixture.standardInstallDirectory
            )
            fixture.defaults.set(
                selected.path,
                forKey: CodebaseMemoryBinaryResolver.selectedExecutablePathKey
            )

            let executable = try await fixture.resolver().resolveExecutableInfo()

            #expect(executable.url == selected.resolvingSymlinksInPath())
            #expect(executable.source == .userSelected)
            #expect(executable.version == "--version")
        }
    }

    @Test("Direct 自动检测 upstream 默认安装目录")
    func directDetectsStandardInstallDirectory() async throws {
        try await withFixture { fixture in
            let installed = try fixture.copyExecutable(
                named: "codebase-memory-mcp",
                directory: fixture.standardInstallDirectory
            )

            let executable = try await fixture.resolver().resolveExecutableInfo()

            #expect(executable.url == installed.resolvingSymlinksInPath())
            #expect(executable.source == .automatic)
        }
    }

    @Test("Direct 的 PATH 优先于 Homebrew 常见目录")
    func directPrefersProcessPathBeforeCommonDirectories() async throws {
        try await withFixture { fixture in
            let pathDirectory = fixture.root.appendingPathComponent("path-bin", isDirectory: true)
            let commonDirectory = fixture.root.appendingPathComponent("common-bin", isDirectory: true)
            let pathExecutable = try fixture.copyExecutable(
                named: "codebase-memory-mcp",
                directory: pathDirectory
            )
            _ = try fixture.copyExecutable(
                named: "codebase-memory-mcp",
                directory: commonDirectory
            )

            let executable = try await fixture.resolver(
                environment: ["PATH": pathDirectory.path],
                commonExecutableDirectories: [commonDirectory]
            ).resolveExecutableInfo()

            #expect(executable.url == pathExecutable.resolvingSymlinksInPath())
            #expect(executable.source == .automatic)
        }
    }

    @Test("失效的用户路径回退自动检测")
    func staleSelectionFallsBackToAutomaticDetection() async throws {
        try await withFixture { fixture in
            fixture.defaults.set(
                fixture.root.appendingPathComponent("missing").path,
                forKey: CodebaseMemoryBinaryResolver.selectedExecutablePathKey
            )
            let installed = try fixture.copyExecutable(
                named: "codebase-memory-mcp",
                directory: fixture.standardInstallDirectory
            )

            let executable = try await fixture.resolver().resolveExecutableInfo()

            #expect(executable.url == installed.resolvingSymlinksInPath())
            #expect(executable.source == .automatic)
        }
    }

    @Test("用户选择验证成功后跨 Resolver 持久化")
    func selectionPersistsAcrossResolverInstances() async throws {
        try await withFixture { fixture in
            let selected = try fixture.copyExecutable(named: "selected")
            let firstResolver = fixture.resolver()

            let selectedResult = try await firstResolver.selectExecutable(selected)
            let restoredResult = try await fixture.resolver().resolveExecutableInfo()

            #expect(selectedResult.source == .userSelected)
            #expect(restoredResult.url == selected.resolvingSymlinksInPath())
            #expect(restoredResult.source == .userSelected)
        }
    }

    @Test("App Store 忽略外部选择并只使用 bundle")
    func appStoreUsesOnlyBundledExecutable() async throws {
        try await withFixture { fixture in
            let selected = try fixture.copyExecutable(named: "selected")
            let bundled = try fixture.copyExecutable(named: "bundled")
            fixture.defaults.set(
                selected.path,
                forKey: CodebaseMemoryBinaryResolver.selectedExecutablePathKey
            )

            let resolver = fixture.resolver(
                channel: .appStore,
                bundledExecutableURL: bundled
            )
            let executable = try await resolver.resolveExecutableInfo()

            #expect(executable.url == bundled.resolvingSymlinksInPath())
            #expect(executable.source == .bundled)
        }
    }

    @Test("版本探测超时错误会保留绝对路径")
    func versionProbeTimeoutPreservesPath() async throws {
        try await withFixture { fixture in
            let endless = try fixture.copyExecutable(named: "endless")
            let resolver = fixture.resolver(versionProbe: { url, _ in
                throw CodebaseMemoryError.executableProbeTimedOut(path: url.path)
            })

            do {
                _ = try await resolver.selectExecutable(endless)
                Issue.record("Expected version probe timeout")
            } catch let error as CodebaseMemoryError {
                guard case .executableProbeTimedOut(let path) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(path == endless.resolvingSymlinksInPath().path)
            }
        }
    }

    @Test("识别 upstream headless 警告且不误判普通启动日志")
    func recognizesHeadlessWarning() {
        #expect(CodebaseMemoryGraphUICapability.reportsUnavailable(
            "codebase-memory-mcp: --ui requested, but this binary was built without the embedded UI, so the HTTP server will not start."
        ))
        #expect(!CodebaseMemoryGraphUICapability.reportsUnavailable(
            "level=info msg=mem.init budget_mb=32768 total_ram_mb=65536"
        ))
    }

    private func withFixture(
        _ operation: (ResolverFixture) async throws -> Void
    ) async throws {
        let fixture = try ResolverFixture()
        defer { fixture.cleanup() }
        try await operation(fixture)
    }
}

/// 每个测试独占临时目录和 UserDefaults suite，避免并行测试互相污染用户选择。
private final class ResolverFixture: @unchecked Sendable {
    let root: URL
    let home: URL
    let defaults: UserDefaults
    let standardInstallDirectory: URL

    private let defaultsSuiteName: String
    private let fileManager = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodebaseMemoryBinaryResolverTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        standardInstallDirectory = home.appendingPathComponent(".local/bin", isDirectory: true)
        defaultsSuiteName = "CodebaseMemoryBinaryResolverTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        try fileManager.createDirectory(
            at: standardInstallDirectory,
            withIntermediateDirectories: true
        )
    }

    func resolver(
        channel: DistributionChannel = .direct,
        environment: [String: String] = ["PATH": ""],
        commonExecutableDirectories: [URL] = [],
        probeTimeout: TimeInterval = 1,
        bundledExecutableURL: URL? = nil,
        versionProbe: CodebaseMemoryBinaryResolver.VersionProbe? = { _, _ in "--version" }
    ) -> CodebaseMemoryBinaryResolver {
        CodebaseMemoryBinaryResolver(
            fileManager: fileManager,
            defaults: defaults,
            channel: channel,
            environment: environment,
            homeDirectory: home,
            commonExecutableDirectories: commonExecutableDirectories,
            probeTimeout: probeTimeout,
            bundledExecutableURL: bundledExecutableURL,
            versionProbe: versionProbe
        )
    }

    func copyExecutable(
        from source: URL = URL(fileURLWithPath: "/bin/echo"),
        named name: String,
        directory: URL? = nil
    ) throws -> URL {
        let targetDirectory = directory ?? root
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let target = targetDirectory.appendingPathComponent(name, isDirectory: false)
        try fileManager.copyItem(at: source, to: target)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? fileManager.removeItem(at: root)
    }
}
