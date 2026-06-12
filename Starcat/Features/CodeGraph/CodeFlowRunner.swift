//
//  CodeFlowRunner.swift
//  Starcat
//
//  CodeFlow 集成的本地流水线：用系统 Git clone 公开仓库，扫描文本源码，
//  将项目数据注入 vendored CodeFlow HTML，再交给默认浏览器自动分析。
//

import Foundation

struct CodeFlowCommandResult: Sendable, Equatable {
    let executable: String
    let arguments: [String]
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var commandDescription: String { ([executable] + arguments).joined(separator: " ") }
}

enum CodeFlowError: LocalizedError, Sendable {
    case privateRepository
    case gitUnavailable
    case commandFailed(CodeFlowCommandResult)
    case templateMissing
    case noSupportedFiles
    case projectTooLarge
    case invalidTemplate

    var errorDescription: String? {
        switch self {
        case .privateRepository: return "首版代码图谱仅支持公开仓库。"
        case .gitUnavailable: return "系统 Git 命令不可用：/usr/bin/git"
        case .commandFailed(let result):
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "拉取仓库失败（exit \(result.exitCode)）：\(stderr.isEmpty ? result.stdout : stderr)"
        case .templateMissing: return "Starcat 安装包中缺少 CodeFlow 页面。"
        case .noSupportedFiles: return "仓库中没有 CodeFlow 支持的文本源码文件。"
        case .projectTooLarge: return "仓库源码超过当前 50 MB 注入上限。"
        case .invalidTemplate: return "CodeFlow 页面缺少 Starcat 数据注入入口。"
        }
    }
}

protocol CodeFlowCommandExecuting: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> CodeFlowCommandResult
}

final class FoundationCodeFlowCommandExecutor: CodeFlowCommandExecuting, @unchecked Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> CodeFlowCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // clone 输出可能超过 Pipe 缓冲区，因此必须在等待进程退出前并发消费两条流。
        async let stdoutData = stdoutPipe.fileHandleForReading.readToEnd()
        async let stderrData = stderrPipe.fileHandleForReading.readToEnd()
        let exitCode = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() }
                catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        return CodeFlowCommandResult(
            executable: executableURL.path,
            arguments: arguments,
            exitCode: exitCode,
            stdout: String(data: try await stdoutData ?? Data(), encoding: .utf8) ?? "",
            stderr: String(data: try await stderrData ?? Data(), encoding: .utf8) ?? ""
        )
    }
}

struct CodeFlowRunner {
    static let gitExecutableURL = URL(fileURLWithPath: "/usr/bin/git")

    private let executor: any CodeFlowCommandExecuting
    private let fileManager: FileManager

    init(
        executor: any CodeFlowCommandExecuting = FoundationCodeFlowCommandExecutor(),
        fileManager: FileManager = .default
    ) {
        self.executor = executor
        self.fileManager = fileManager
    }

    func cloneIfNeeded(repo: Repo) async throws -> (URL, CodeFlowCommandResult?) {
        guard !repo.isPrivate else { throw CodeFlowError.privateRepository }
        guard fileManager.isExecutableFile(atPath: Self.gitExecutableURL.path) else {
            throw CodeFlowError.gitUnavailable
        }

        let destination = try repositoryDirectory(owner: repo.owner, name: repo.name)
        guard !fileManager.fileExists(atPath: destination.path) else { return (destination, nil) }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cloneURL = repo.cloneUrl?.isEmpty == false
            ? repo.cloneUrl!
            : "https://github.com/\(repo.owner)/\(repo.name).git"
        let result = try await executor.run(
            executableURL: Self.gitExecutableURL,
            arguments: ["clone", "--depth=1", cloneURL, destination.path]
        )
        guard result.exitCode == 0 else { throw CodeFlowError.commandFailed(result) }
        return (destination, result)
    }

    func makeVisualizationPage(repositoryURL: URL, owner: String, name: String) throws -> URL {
        guard let templateURL = Bundle.main.url(forResource: "codeflow", withExtension: "html", subdirectory: "CodeFlow")
            ?? Bundle.main.url(forResource: "codeflow", withExtension: "html") else {
            throw CodeFlowError.templateMissing
        }
        let files = try sourceFiles(in: repositoryURL)
        guard !files.isEmpty else { throw CodeFlowError.noSupportedFiles }

        let payload = CodeFlowProjectPayload(name: name, files: files)
        let encoded = try JSONEncoder().encode(payload).base64EncodedString()
        var html = try String(contentsOf: templateURL, encoding: .utf8)
        let token = "__STARCAT_CODEFLOW_PAYLOAD_TOKEN__"
        guard html.contains(token) else { throw CodeFlowError.invalidTemplate }
        html = html.replacingOccurrences(of: token, with: encoded)

        let outputURL = try visualizationDirectory(owner: owner, name: name)
            .appendingPathComponent("index.html", isDirectory: false)
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    func repositoryDirectory(owner: String, name: String) throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("repos/github.com", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func visualizationDirectory(owner: String, name: String) throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("codeflow", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func applicationSupportDirectory() throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Starcat", isDirectory: true)
    }

    private func sourceFiles(in repositoryURL: URL) throws -> [CodeFlowProjectFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: repositoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [CodeFlowProjectFile] = []
        var totalBytes = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true, Self.excludedDirectories.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let size = values.fileSize ?? 0
            guard size <= 1_000_000 else { continue }
            totalBytes += size
            guard totalBytes <= 50_000_000 else { throw CodeFlowError.projectTooLarge }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: repositoryURL.path + "/", with: "")
            files.append(CodeFlowProjectFile(path: relativePath, content: content))
        }
        return files.sorted { $0.path < $1.path }
    }

    private static let excludedDirectories: Set<String> = [
        ".git", ".build", "build", "dist", "DerivedData", "node_modules", "Pods", "vendor"
    ]

    private static let supportedExtensions: Set<String> = [
        "js", "jsx", "ts", "tsx", "html", "htm", "xhtml", "py", "java", "go", "rb", "php",
        "vue", "svelte", "rs", "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "cs", "swift",
        "kt", "kts", "scala", "sc", "groovy", "gvy", "ex", "exs", "erl", "hrl", "hs", "lhs",
        "lua", "r", "jl", "dart", "pl", "pm", "sh", "bash", "zsh", "fish", "ps1", "psm1", "psd1",
        "fs", "fsi", "fsx", "ml", "mli", "clj", "cljs", "cljc", "elm", "md", "markdown"
    ]
}

private struct CodeFlowProjectPayload: Codable {
    let name: String
    let files: [CodeFlowProjectFile]
}

private struct CodeFlowProjectFile: Codable {
    let path: String
    let content: String
}
