//
//  RAGAttachmentProcessor.swift
//  Starcat
//
//  用户本轮附件的本地读取与预算控制。附件内容不会写入 rag_chunks、笔记或 CloudKit。
//

import Foundation
import PDFKit

struct RAGAttachmentContext: Equatable, Sendable {
    var attachmentID: UUID
    var filename: String
    var content: String
    var imageData: Data? = nil
    var contentType: String? = nil
    /// 真正的附件正文或图片可以作为本轮证据；仅粘贴的 GitHub URL 关系说明不可以据此
    /// 生成仓库事实，避免把“用户给了一个链接”误判成“已经拿到了链接内容”。
    var supportsFactualAnswer = true
}

enum RAGAttachmentError: Error, LocalizedError, Equatable {
    case tooManyFiles
    case fileTooLarge(String)
    case totalTooLarge
    case unsupported(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles:
            return String.l10n("rag.core.attachment.error.tooManyFiles")
        case .fileTooLarge(let name):
            return String(format: String.l10n("rag.core.attachment.error.fileTooLargeFormat"), name)
        case .totalTooLarge:
            return String.l10n("rag.core.attachment.error.totalTooLarge")
        case .unsupported(let name):
            return String(format: String.l10n("rag.core.attachment.error.unsupportedFormat"), name)
        case .unreadable(let name):
            return String(format: String.l10n("rag.core.attachment.error.unreadableFormat"), name)
        }
    }
}

protocol RAGAttachmentProcessing: Sendable {
    func process(_ attachments: [RAGComposerAttachment]) async throws -> [RAGAttachmentContext]
}

struct RAGAttachmentProcessor: RAGAttachmentProcessing {
    private let maxFiles = 5
    private let maxFileBytes: Int64 = 10 * 1_024 * 1_024
    private let maxTotalBytes: Int64 = 20 * 1_024 * 1_024
    private let maxCharactersPerFile = 40_000
    /// UTF-8 单字符最多四字节；文本读取只需要到此上限便可满足 Prompt 字符预算。
    private let maxTextBytesToRead = 40_000 * 4 + 4
    private let textReadChunkSize = 16 * 1_024

    func process(_ attachments: [RAGComposerAttachment]) async throws -> [RAGAttachmentContext] {
        guard attachments.count <= maxFiles else { throw RAGAttachmentError.tooManyFiles }
        // 文件从选择到发送之间可能被替换；预算必须按发送时的实际文件大小校验，不能只信
        // Composer 创建 chip 时保存的旧 size。
        let sizedAttachments = attachments.map { attachment -> (RAGComposerAttachment, Int64) in
            let currentSize = try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return (attachment, Int64(currentSize ?? Int(attachment.sizeInBytes)))
        }
        guard sizedAttachments.reduce(Int64(0), { $0 + $1.1 }) <= maxTotalBytes else {
            throw RAGAttachmentError.totalTooLarge
        }
        var contexts: [RAGAttachmentContext] = []
        for (attachment, actualSize) in sizedAttachments {
            try Task.checkCancellation()
            guard actualSize <= maxFileBytes else {
                throw RAGAttachmentError.fileTooLarge(attachment.filename)
            }
            switch attachment.handling {
            case .textContext:
                guard let text = try await textContent(for: attachment) else {
                    throw RAGAttachmentError.unreadable(attachment.filename)
                }
                contexts.append(RAGAttachmentContext(
                    attachmentID: attachment.id,
                    filename: attachment.filename,
                    content: text
                ))
            case .vision:
                guard let data = try? Data(contentsOf: attachment.localURL), !data.isEmpty else {
                    throw RAGAttachmentError.unreadable(attachment.filename)
                }
                contexts.append(RAGAttachmentContext(
                    attachmentID: attachment.id,
                    filename: attachment.filename,
                    // vision content 是传给多模态 Provider 的稳定 Prompt 标签，不进入 UI。
                    content: "图片附件：\(attachment.filename)",
                    imageData: data,
                    contentType: attachment.contentType
                ))
            case .unsupported:
                throw RAGAttachmentError.unsupported(attachment.filename)
            }
        }
        return contexts
    }

    private func textContent(for attachment: RAGComposerAttachment) async throws -> String? {
        if attachment.contentType == "application/pdf" || attachment.localURL.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: attachment.localURL) else { return nil }
            return try pdfText(document)
        }
        let data = try readTextPrefix(from: attachment.localURL)
        guard !data.isEmpty else { return nil }
        return (String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode))
            .map { String($0.prefix(maxCharactersPerFile)) }
    }

    /// PDFKit 的 `page.string` 本身无法流式化，但页面可逐页释放。达到文本预算或任务取消后
    /// 立即停止，不能为最终只会发送 4 万字符的 Prompt 把整份 PDF 拼成一个大字符串。
    private func pdfText(_ document: PDFDocument) throws -> String {
        var result = ""
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let pageText = document.page(at: pageIndex)?.string, !pageText.isEmpty else { continue }
            let remaining = maxCharactersPerFile - result.count
            guard remaining > 0 else { break }
            if !result.isEmpty { result += "\n\n" }
            result += String(pageText.prefix(remaining))
        }
        return result
    }

    /// 普通文本只读取足够生成 Prompt 的前缀。读取循环保留取消点，避免大日志或导出文件
    /// 在用户已经停止问答后仍占用主链 I/O。
    private func readTextPrefix(from url: URL) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        var data = Data()
        while data.count < maxTextBytesToRead {
            try Task.checkCancellation()
            let remaining = maxTextBytesToRead - data.count
            guard let chunk = try handle.read(upToCount: min(textReadChunkSize, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }
}
