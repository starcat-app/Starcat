//
//  SkillAgentProfile.swift
//  Starcat
//
//  复用现有 Agent 目录表建立只读发现根，不再维护第二套安装路径。
//  发现能力不承诺 Agent 已加载内容，分配操作仍须使用各工具的明确目标。
//

import Foundation

/// 配置根保持词法路径身份；物理解析留给 scanner，避免提前吞掉权限与链接错误。
enum SkillAgentProfile {
    static func roots(
        home: URL,
        environment: [String: String],
        detectedPresets: Set<RepoSkillTargetPreset>,
        previous: [SkillLibraryRoot],
        managed: URL
    ) -> [SkillLibraryRoot] {
        var consumers: [String: Set<String>] = [:]
        let shared = RepoSkillTargetPreset.agents.agent.directoryURL(home: home, environment: environment)
            .standardizedFileURL.path
        consumers[shared] = []
        for preset in RepoSkillTargetPreset.allCases where preset != .agents {
            let path = preset.agent.directoryURL(home: home, environment: environment).standardizedFileURL.path
            // 通用根只列实际检测到的工具，不能把目录表的全部品牌显示成“已安装”。
            if path != shared || detectedPresets.contains(preset) {
                consumers[path, default: []].insert(preset.rawValue)
            }
        }
        // OpenCode 官方列出的兼容根是只读可见性证据，不是新的独占分配目标。
        if detectedPresets.contains(.openCode) {
            consumers[shared, default: []].insert(RepoSkillTargetPreset.openCode.rawValue)
            let claude = RepoSkillTargetPreset.claudeCode.agent.directoryURL(home: home, environment: environment)
            consumers[claude.standardizedFileURL.path, default: []].insert(RepoSkillTargetPreset.openCode.rawValue)
        }
        // 本机 Codex skill catalog 与内置 .system 独立发现；不能因跳过点目录漏掉它。
        let codex = RepoSkillTargetPreset.codex.agent.configurationURL(home: home, environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
        for url in [codex, codex.appendingPathComponent(".system", isDirectory: true)] {
            consumers[url.standardizedFileURL.path, default: []].insert(RepoSkillTargetPreset.codex.rawValue)
        }
        let existing = Dictionary(uniqueKeysWithValues: previous.map { ($0.configuredPath, $0) })
        var result = consumers.keys.sorted().map { path in
            var root = existing[path] ?? SkillLibraryRoot(
                configuredPath: path, agentIDs: [], scope: .global
            )
            root.agentIDs = consumers[path, default: []].sorted()
            return root
        }
        let managedPath = managed.standardizedFileURL.path
        result.append(existing[managedPath] ?? SkillLibraryRoot(
            configuredPath: managedPath, agentIDs: [], scope: .managed
        ))
        return result
    }

    static func displayName(for identifier: String) -> String {
        RepoSkillTargetPreset(rawValue: identifier)?.agent.name ?? identifier
    }
}
