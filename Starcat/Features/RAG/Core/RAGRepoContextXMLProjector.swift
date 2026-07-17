//
//  RAGRepoContextXMLProjector.swift
//  Starcat
//
//  在模型总 Context Window 不足时，对 RepoContext 做 XML 感知投影。
//
//  关键约束：RepoContext 不参与 RAG 分片 evidence budget，但仍不能突破模型总窗口。
//  因此这里按完整 XML 节点删减，而不是用字符硬截断生成无法解析的半段 XML。
//

import Foundation

struct RAGRepoContextProjection: Equatable, Sendable {
    var xml: String
    var originalTokens: Int
    var projectedTokens: Int
    var wasProjected: Bool
    var removedFileCount: Int
    var reason: String?
}

enum RAGRepoContextXMLProjectorError: Error, Equatable {
    case invalidXML
    case budgetTooSmall
}

struct RAGRepoContextXMLProjector: Sendable {
    /// 优先移除仅含路径的 fileList，再移除 keyFiles，最后才移除 entryPoints。
    /// directoryStructure 与 stats 保留到最后；极小窗口下只缩短目录 CDATA，仍保持合法 XML。
    func project(_ xml: String, tokenBudget: Int) throws -> RAGRepoContextProjection {
        let originalTokens = TokenEstimator.estimate(text: xml)
        guard tokenBudget > 0 else { throw RAGRepoContextXMLProjectorError.budgetTooSmall }
        guard originalTokens > tokenBudget else {
            return RAGRepoContextProjection(
                xml: xml,
                originalTokens: originalTokens,
                projectedTokens: originalTokens,
                wasProjected: false,
                removedFileCount: 0,
                reason: nil
            )
        }

        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        } catch {
            throw RAGRepoContextXMLProjectorError.invalidXML
        }
        guard let root = document.rootElement(), root.name == "repository" else {
            throw RAGRepoContextXMLProjectorError.invalidXML
        }

        let truncation = XMLElement(name: "truncation")
        truncation.addAttribute(XMLNode.attribute(withName: "reason", stringValue: "model_context_window") as! XMLNode)
        truncation.addAttribute(XMLNode.attribute(withName: "originalTokens", stringValue: String(originalTokens)) as! XMLNode)
        root.addChild(truncation)

        var removedFiles = 0
        for sectionName in ["fileList", "keyFiles", "entryPoints"] {
            guard let section = root.elements(forName: sectionName).first else { continue }
            while estimatedTokens(document) > tokenBudget,
                  let file = section.elements(forName: "file").last {
                file.detach()
                removedFiles += 1
            }
        }

        // 目录树可能比极小窗口还大。只裁 CDATA 的文本值，XML tag 和其它完整元素不动。
        if estimatedTokens(document) > tokenBudget,
           let directory = root.elements(forName: "directoryStructure").first,
           let value = directory.stringValue {
            var lower = 0
            var upper = value.count
            var best = ""
            let characters = Array(value)
            while lower <= upper {
                let middle = (lower + upper) / 2
                directory.stringValue = String(characters.prefix(middle)) + "\n[truncated]"
                if estimatedTokens(document) <= tokenBudget {
                    best = directory.stringValue ?? ""
                    lower = middle + 1
                } else {
                    upper = middle - 1
                }
            }
            directory.stringValue = best
        }

        truncation.addAttribute(XMLNode.attribute(withName: "removedFiles", stringValue: String(removedFiles)) as! XMLNode)
        let projectedXML = document.xmlString(options: [.nodePrettyPrint])
        let projectedTokens = TokenEstimator.estimate(text: projectedXML)
        guard !projectedXML.isEmpty, projectedTokens <= tokenBudget else {
            throw RAGRepoContextXMLProjectorError.budgetTooSmall
        }
        // 回读一次保证输出不是“看起来像 XML”的坏字符串。
        guard (try? XMLDocument(xmlString: projectedXML))?.rootElement()?.name == "repository" else {
            throw RAGRepoContextXMLProjectorError.invalidXML
        }
        return RAGRepoContextProjection(
            xml: projectedXML,
            originalTokens: originalTokens,
            projectedTokens: projectedTokens,
            wasProjected: true,
            removedFileCount: removedFiles,
            reason: "model_context_window"
        )
    }

    private func estimatedTokens(_ document: XMLDocument) -> Int {
        TokenEstimator.estimate(text: document.xmlString(options: [.nodePrettyPrint]))
    }
}
