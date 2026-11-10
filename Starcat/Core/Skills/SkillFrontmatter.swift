//
//  SkillFrontmatter.swift
//  Starcat
//
//  有界读取 Skill 的 YAML 描述字段。只解释字符串，不构造 YAML 对象或展开 tag/alias。
//  无法明确解码的语法保留为诊断，不能据此把整仓判断为“不包含 Skill”。
//

import Foundation

/// 支持常见 plain / quoted / literal / folded scalar；未知复杂语法明确失败，不猜测名称。
enum SkillFrontmatter {
    struct Metadata: Equatable, Sendable {
        let name: String
        let description: String
    }

    /// 预览正文去掉开头 frontmatter；无法识别时保持原文，识别失败由 parse 单独报诊断。
    static func stripFrontmatter(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .init(charactersIn: "\u{feff}"))
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." })
        else { return normalized }
        // dropFirst 返回原数组索引空间，end 即结束行的原始下标。
        let bodyStart = lines.index(after: end)
        guard lines.indices.contains(bodyStart) else { return "" }
        return lines[bodyStart...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只读取开头 frontmatter，正文中的 YAML 或示例 SKILL.md 不参与识别。
    static func parse(_ markdown: String, directory: String) throws -> Metadata {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .init(charactersIn: "\u{feff}"))
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }),
              end <= 2_048 else { throw RepoSkillError.invalidManifest }
        var values: [String: String] = [:]
        var seen: Set<String> = []
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            guard !line.hasPrefix("\t") else { throw RepoSkillError.invalidManifest }
            // 未使用的嵌套 metadata / hooks 不参与名称推断；仍保留原文供目标工具解释。
            if line.hasPrefix(" ") { continue }
            guard let colon = line.firstIndex(of: ":") else { throw RepoSkillError.invalidManifest }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, seen.insert(key).inserted else { throw RepoSkillError.invalidManifest }
            guard key == "name" || key == "description" else { continue }
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let value: String
            if raw.first == "|" || raw.first == ">" {
                guard raw.allSatisfy({ "|>+-123456789".contains($0) }) else { throw RepoSkillError.invalidManifest }
                var block: [String] = []
                while index < end && (lines[index].hasPrefix(" ") || lines[index].isEmpty) {
                    block.append(lines[index])
                    index += 1
                }
                let indent = block.filter { !$0.isEmpty }.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
                let content = block.map { String($0.dropFirst(min(indent, $0.count))) }
                value = content.joined(separator: raw.first == ">" ? " " : "\n")
            } else {
                var scalar = raw
                // YAML 允许普通及引号字符串续行；折叠成空格后再处理引号转义。
                while index < end, lines[index].hasPrefix(" ") {
                    scalar += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                value = try decodeScalar(scalar)
            }
            values[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = values["name"], let description = values["description"],
              isValidName(name), (1...1_024).contains(description.count),
              directory.isEmpty || directory.split(separator: "/").last.map(String.init) == name
        else { throw RepoSkillError.invalidManifest }
        return Metadata(name: name, description: description)
    }

    /// Agent Skills 允许 Unicode 小写字母和数字；连字符不能连续或位于两端。
    static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.count)
            && name.range(of: #"^[\p{Ll}\p{Nd}]+(?:-[\p{Ll}\p{Nd}]+)*$"#, options: .regularExpression) != nil
    }

    private static func decodeScalar(_ raw: String) throws -> String {
        if raw.hasPrefix("\"") {
            // JSON 字符串是 YAML 双引号字符串的安全子集；不支持的 escape 不静默改写。
            guard let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(String.self, from: data)
            else { throw RepoSkillError.invalidManifest }
            return value
        }
        if raw.hasPrefix("'") {
            guard raw.count >= 2, raw.hasSuffix("'") else { throw RepoSkillError.invalidManifest }
            let inner = String(raw.dropFirst().dropLast())
            guard !inner.replacingOccurrences(of: "''", with: "").contains("'") else {
                throw RepoSkillError.invalidManifest
            }
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        guard !raw.isEmpty, !"[{&*!?>".contains(raw.first!),
              !raw.contains(": "), !["null", "~", "true", "false"].contains(raw.lowercased())
        else { throw RepoSkillError.invalidManifest }
        return raw.components(separatedBy: " #").first ?? raw
    }
}
