// MARK: - DefaultDirectoryTreeBuilder
//
// Pass 2/3：基于 FilteredFile 列表生成「缩进列表」格式的目录树。
//
// 决议（§22.10 反对意见）：MVP 用**缩进列表**（不用 ASCII tree `├──` `└──`）—— 等价信息、
// 每行省 2-4 字符 token，5000 文件项目省约 500 token。
//
// 输出示例：
//   ```
//   src/
//     index.ts
//     utils/
//       helper.ts
//       parser.ts
//   README.md
//   package.json
//   ```
//
// 关键不变量：
//   - 按 path 字典序输出（与 BudgetAllocator 顺序一致）
//   - 缩进用 2 空格（与 XML 缩进保持一致）
//   - 不读文件内容（只用 relativePath）

import Foundation

public struct DefaultDirectoryTreeBuilder: DirectoryTreeBuilding {

    public init() {}

    public func build(_ files: [FilteredFile]) -> String {
        // 按 path 字典序排序（caller 可能没排，保证幂等）
        let sorted = files.sorted { $0.relativePath < $1.relativePath }

        // 构造目录树节点
        // 用一个 dictionary 跟踪每个目录的「上次输出过的祖先路径」，避免重复输出 `src/` 标头
        var lastPrintedDirs: [String] = []
        var lines: [String] = []

        for file in sorted {
            let components = file.relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            // 1. 输出所有「还没输出过」的祖先目录
            let dirComponents = Array(components.dropLast())
            for (i, dir) in dirComponents.enumerated() {
                // 判定该层级是否已经输出过同名祖先
                let alreadyPrinted = i < lastPrintedDirs.count && lastPrintedDirs[i] == dir
                if !alreadyPrinted {
                    let indent = String(repeating: "  ", count: i)
                    lines.append("\(indent)\(dir)/")
                }
            }

            // 2. 输出文件名
            let fileIndent = String(repeating: "  ", count: dirComponents.count)
            let filename = components.last!
            lines.append("\(fileIndent)\(filename)")

            // 3. 更新 lastPrintedDirs（截断到当前文件的祖先层级）
            lastPrintedDirs = dirComponents
        }

        return lines.joined(separator: "\n")
    }
}
