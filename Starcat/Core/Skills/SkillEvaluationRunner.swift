//
//  SkillEvaluationRunner.swift
//  Starcat
//
//  固定 SkillEvaluator CLI 的输入、环境和生命周期。原始报告只在任务临时目录内存在。
//

import Darwin
import Foundation

/// Direct 的外部评估器入口。手动选择的二进制与其安装目录属于受信任工具。
struct SkillEvaluationRunner {
    static let version = "1.0.1"
    static let maximumReportBytes = 8 * 1024 * 1024
    private static let systemPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// GUI 的 PATH 常不含用户级 CLI。手动选择优先，失效时返回明确错误。
    static func locate(override: URL?) throws -> URL {
        let homeBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let candidates = override.map { [$0] } ?? ([homeBin.path] + systemPaths).map {
            URL(fileURLWithPath: $0).appendingPathComponent("skillevaluator")
        }
        for candidate in candidates where candidate.isFileURL {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  FileManager.default.isExecutableFile(atPath: resolved.path) else { continue }
            return resolved
        }
        throw SkillEvaluationFailure("toolMissing")
    }

    /// 每次探测精确版本。探测进程只收到基础环境和版本参数。
    @concurrent
    static func run(
        executable: URL, mode: SkillEvaluationMode, inputs: [SkillEvaluationInput],
        workspace: URL, model: SkillEvaluationSelection?, apiKey: String?
    ) async throws -> [SkillEvaluationCheck] {
        do {
            return try await evaluate(executable, mode, inputs, workspace, model, apiKey)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SkillEvaluationFailure {
            throw failure
        } catch {
            // Cocoa/POSIX 的错误可能包含宿主路径。
            throw SkillEvaluationFailure("failed")
        }
    }

    @concurrent
    private static func evaluate(
        _ executable: URL, _ mode: SkillEvaluationMode, _ inputs: [SkillEvaluationInput],
        _ workspace: URL, _ model: SkillEvaluationSelection?, _ apiKey: String?
    ) async throws -> [SkillEvaluationCheck] {
        try Task.checkCancellation()
        guard workspace.isFileURL, inputs.allSatisfy({ $0.root.isFileURL }) else {
            throw SkillEvaluationFailure("input")
        }
        let requestedExecutable = try physicalURL(executable.standardizedFileURL.deletingLastPathComponent())
            .appendingPathComponent(executable.lastPathComponent)
        let executable = try physicalURL(locate(override: executable))
        let workspace = try physicalURL(workspace)
        let roots = try inputs.map { try physicalURL($0.root) }
        let requiredCount = mode == .similarity ? roots.count >= 2 : roots.count == 1
        guard requiredCount, Set(roots.map(\.path)).count == roots.count,
              roots.allSatisfy({ $0.path.hasPrefix(workspace.path + "/") }),
              !requestedExecutable.path.hasPrefix(workspace.path + "/"),
              !executable.path.hasPrefix(workspace.path + "/") else { throw SkillEvaluationFailure("input") }
        let files = try roots.map(snapshotFiles)
        let credentials = try modelEnvironment(mode: mode, model: model, apiKey: apiKey)

        let job = workspace.appendingPathComponent("runner-" + UUID().uuidString, isDirectory: true)
        try makeDirectory(job)
        defer { try? FileManager.default.removeItem(at: job) }
        let cwd = job.appendingPathComponent("cwd", isDirectory: true)
        let home = job.appendingPathComponent("home", isDirectory: true)
        let output = job.appendingPathComponent("reports", isDirectory: true)
        try makeDirectory(cwd)
        try makeDirectory(home)
        try makeDirectory(output)

        // 不继承宿主 PATH。受信任的安装目录可为 venv 提供 uv/Python。
        let bin = executable.deletingLastPathComponent().path
        guard !bin.contains(":") else { throw SkillEvaluationFailure("input") }
        var environment = [
            "PATH": ([bin] + systemPaths).joined(separator: ":"),
            "HOME": home.path, "TMPDIR": job.path,
            "PYTHON_DOTENV_DISABLED": "1", "PYTHONNOUSERSITE": "1", "PYTHONUTF8": "1",
            "UV_NO_CONFIG": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CEILING_DIRECTORIES": workspace.path,
        ]
        let versionFile = job.appendingPathComponent("version")
        let probe = try await SkillEvaluationChild.run(
            executable, arguments: ["--version"], environment: environment, cwd: cwd,
            stdout: versionFile, watchedFile: versionFile, byteLimit: 512, timeout: .seconds(10),
            budgetError: "toolVersion"
        )
        let versionData = try readRegularFile(versionFile, limit: 512, errorCode: "toolVersion")
        guard probe == 0, String(data: versionData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) == "skillevaluator, version \(version)" else {
            throw SkillEvaluationFailure("toolVersion")
        }

        var target = roots[0]
        if mode == .similarity {
            // 递归发现只见所选条目的根清单，附件里的嵌套 Skill 不属于比较集合。
            target = job.appendingPathComponent("selection", isDirectory: true)
            try makeDirectory(target)
            for (index, root) in roots.enumerated() {
                try Task.checkCancellation()
                let item = target.appendingPathComponent("item-\(index + 1)", isDirectory: true)
                try makeDirectory(item)
                try FileManager.default.copyItem(at: root.appendingPathComponent("SKILL.md"),
                                                 to: item.appendingPathComponent("SKILL.md"))
            }
        }
        environment.merge(credentials) { _, selected in selected }
        let command = command(for: mode)
        let report = output.appendingPathComponent("skillevaluator-\(command.report).json")
        let status = try await SkillEvaluationChild.run(
            executable, arguments: command.arguments + ["--report", "json", "--output-dir", output.path, target.path],
            environment: environment, cwd: cwd, stdout: nil, watchedFile: report,
            byteLimit: maximumReportBytes, timeout: command.timeout, budgetError: "invalidReport"
        )
        guard status == 0 || status == 1 else { throw SkillEvaluationFailure("failed") }
        let data = try readRegularFile(report, limit: maximumReportBytes, errorCode: "invalidReport")
        var checks = try SkillEvaluationReportParser.parse(
            data, mode: mode, exitStatus: status, roots: roots, files: files, chatModel: model?.chat
        )
        if mode == .quick {
            // Tier 1 JSON 省略兼容矩阵。独立命令失败时仍保留已完成的结构与质量证据。
            let harnessReport = output.appendingPathComponent("harness.json")
            let harnessData: Data?
            do {
                let status = try await SkillEvaluationChild.run(
                    executable, arguments: ["harness-check", "--json", harnessReport.path, target.path],
                    environment: environment, cwd: cwd, stdout: nil, watchedFile: harnessReport,
                    byteLimit: maximumReportBytes, timeout: .seconds(30), budgetError: "invalidReport"
                )
                harnessData = status == 0
                    ? try readRegularFile(harnessReport, limit: maximumReportBytes, errorCode: "invalidReport") : nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                harnessData = nil
            }
            checks.append(SkillEvaluationReportParser.harness(harnessData, root: target))
        }
        try Task.checkCancellation()
        return checks
    }

    /// 固定命令表。Tier 1 显式关闭自动模型阶段。
    static func command(for mode: SkillEvaluationMode) -> (arguments: [String], report: String, timeout: Duration) {
        switch mode {
        case .quick: (["tier1", "--checks", "schema,quality", "--no-llm"], "tier1", .seconds(60))
        case .security: (["tier1", "--checks", "security", "--no-llm"], "tier1", .seconds(420))
        case .rubric: (["rubric-eval"], "rubric", .seconds(180))
        case .context: (["context-optimization-check"], "context", .seconds(300))
        case .similarity: (["similarity-check", "--type", "skill"], "similarity", .seconds(180))
        }
    }

    /// OpenAI-compatible 分支使用专用变量。similarity 只做 embedding。
    static func modelEnvironment(
        mode: SkillEvaluationMode, model: SkillEvaluationSelection?, apiKey: String?
    ) throws -> [String: String] {
        guard mode.requiresAI else { return [:] }
        guard let model, let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\0"), let endpoint = URLComponents(string: model.endpoint),
              let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              !model.endpoint.contains("\\"), !model.endpoint.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { throw SkillEvaluationFailure("model") }

        var result: [String: String] = [:]
        if mode.needsChat {
            guard validModel(model.chat) else { throw SkillEvaluationFailure("model") }
            result["SKILL_EVAL_LLM_PROVIDER"] = "openai-compatible"
            result["SKILL_EVAL_LLM_BASE_URL"] = model.endpoint
            result["SKILL_EVAL_LLM_MODEL"] = model.chat
            result["SKILL_EVAL_LLM_API_KEY"] = apiKey
            result["SKILL_EVAL_LLM_REFUSAL_FALLBACK_MODEL"] = "none"
        }
        if mode.needsEmbedding {
            guard let embedding = model.embedding, validModel(embedding) else { throw SkillEvaluationFailure("model") }
            result["SKILL_EVAL_EMBEDDING_PROVIDER"] = "openai-compatible"
            result["SKILL_EVAL_EMBEDDING_BASE_URL"] = model.endpoint
            result["SKILL_EVAL_EMBEDDING_MODEL"] = embedding
            result["SKILL_EVAL_EMBEDDING_API_KEY"] = apiKey
        }
        return result
    }

    private static func validModel(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}\z"#, options: .regularExpression) != nil
            && !value.contains("://") && !value.hasPrefix("sk-") && !value.hasPrefix("nvapi-")
    }

    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// 用物理路径核对上游 Python 报告。Foundation 可能保留 `/tmp`、`/var` 别名，
    /// 但目录枚举与 Python `Path.resolve()` 会返回 `/private` 下的路径。
    private static func physicalURL(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw SkillEvaluationFailure("input") }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    /// 校验快照以数据文件交给上游，并给报告提供可信的文件位置索引。
    private static func snapshotFiles(_ root: URL) throws -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard try root.resourceValues(forKeys: keys).isDirectory == true,
              let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
        else { throw SkillEvaluationFailure("input") }
        var files: [String] = []
        for case let item as URL in entries {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink == false else { throw SkillEvaluationFailure("input") }
            if values.isDirectory == true { continue }
            let prefix = root.path + "/"
            guard values.isRegularFile == true, item.path.hasPrefix(prefix),
                  !FileManager.default.isExecutableFile(atPath: item.path) else {
                throw SkillEvaluationFailure("input")
            }
            files.append(String(item.path.dropFirst(prefix.count)))
        }
        guard files.contains("SKILL.md") else { throw SkillEvaluationFailure("input") }
        return files.sorted()
    }

    /// O_NOFOLLOW 与有界读取拒绝链接、管道和超大报告。
    private static func readRegularFile(_ url: URL, limit: Int, errorCode: String) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SkillEvaluationFailure(errorCode) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count == info.st_size
        else { throw SkillEvaluationFailure(errorCode) }
        return data
    }
}

/// 在 exec 前隔离进程组，把固定上游启动的 uv 和 scanner 纳入同一任务。
enum SkillEvaluationChild {
    @concurrent
    static func run(
        _ executable: URL, arguments: [String], environment: [String: String], cwd: URL,
        stdout: URL?, watchedFile: URL, byteLimit: Int, timeout: Duration, budgetError: String
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let pid = try spawn(executable, arguments, environment, cwd, stdout)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while true {
                try Task.checkCancellation()
                var info = stat()
                if lstat(watchedFile.path, &info) == 0,
                   info.st_mode & S_IFMT != S_IFREG || info.st_size > byteLimit {
                    throw SkillEvaluationFailure(budgetError)
                }
                var child = siginfo_t()
                // WNOWAIT 保留组长 PID，确保发给 -pid 的信号只属于这次任务。
                let code = waitid(P_PID, id_t(pid), &child, WEXITED | WNOHANG | WNOWAIT)
                if code == 0, child.si_pid == pid { break }
                if code != 0, errno != EINTR { throw SkillEvaluationFailure("failed") }
                guard ContinuousClock.now < deadline else { throw SkillEvaluationFailure("timeout") }
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            _ = await finish(pid)
            throw error
        }
        let status = await finish(pid)
        try Task.checkCancellation()
        return status
    }

    /// 即使组长先退出也终止同组后代，等退出后才允许调用方清理临时数据。
    private static func finish(_ pid: pid_t) async -> Int32 {
        _ = Darwin.kill(-pid, SIGKILL)
        var status: Int32 = 0
        var result: pid_t = 0
        repeat {
            result = waitpid(pid, &status, WNOHANG)
            if result == 0 { await pauseForExit() }
        } while result == 0 || (result < 0 && errno == EINTR)
        while Darwin.kill(-pid, 0) == 0 { await pauseForExit() }
        guard result == pid, status & 0x7f == 0 else { return -1 }
        return (status >> 8) & 0xff
    }

    /// 清理也必须在取消后等待，因此延迟独立于调用 Task 的取消状态。
    private static func pauseForExit() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
        }
    }

    private static func spawn(
        _ executable: URL, _ arguments: [String], _ environment: [String: String],
        _ cwd: URL, _ stdout: URL?
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        try require(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        try require(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }

        try require(posix_spawnattr_setpgroup(&attributes, 0))
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        try require(posix_spawnattr_setsigmask(&attributes, &unblocked))
        try require(posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        )))
        if #available(macOS 26, *) {
            try require(posix_spawn_file_actions_addchdir(&actions, cwd.path))
        } else {
            try require(posix_spawn_file_actions_addchdir_np(&actions, cwd.path))
        }
        try require(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try require(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        try require(posix_spawn_file_actions_addopen(
            &actions, STDOUT_FILENO, stdout?.path ?? "/dev/null",
            stdout == nil ? O_WRONLY : O_WRONLY | O_CREAT | O_EXCL, 0o600
        ))

        var argv = ([executable.path] + arguments).map { strdup($0) }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard !argv.contains(nil), !envp.contains(nil) else { throw SkillEvaluationFailure("failed") }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        try require(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp))
        return pid
    }

    private static func require(_ result: Int32) throws {
        guard result == 0 else { throw SkillEvaluationFailure("failed") }
    }
}
