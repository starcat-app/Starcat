//
//  RuntimeDownloadSmoke.swift
//
//  在无沙盒命令行进程中运行生产安装器，验证 Direct 专属下载/解压/签名/协议链。
//  归档必须由调用者提前下载；测试不联网、不保存 App 配置、不访问真实 daemon/cache。
//

import Foundation

/// CLI 不加载 App 的语言设置，错误中保留 key，便于精确识别失败步骤。
extension String {
    static func l10n(_ key: String) -> String { key }
}

/// 直接编译生产安装器，避免 App Store 单测 host 的沙盒阻止 Direct 二进制探测。
@main
struct RuntimeDownloadSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: RuntimeDownloadSmoke <archive-directory>")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("starcat-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (runtime, archive) in [(DownloadableRuntime.codex, "codex-app-server-package-aarch64-apple-darwin.tar.gz"),
                                    (.deepSeek, "deepseek-full.whl"), (.codebaseMemory, "codebase-full.tar.gz")] {
            let installer = RuntimeDownloadInstaller(download: { request, _ in
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: source.appendingPathComponent(archive), to: copy)
                return (copy, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let installed = try await installer.install(runtime, channel: .direct, root: root) { _ in }
            precondition(FileManager.default.isExecutableFile(atPath: installed.executable.path))
            precondition(installed.reportedVersion.contains(runtime.executableVersion))
            precondition(installed.directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
            if runtime == .deepSeek {
                let config = try String(contentsOf: installed.configuration!, encoding: .utf8)
                precondition(config.contains("persistent-bash\n  disabled: true"))
            }
            print("\(runtime.rawValue): \(installed.reportedVersion) — archive, layout, signature, initialize passed")
        }
    }
}
