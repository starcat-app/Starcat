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
}

enum RAGAttachmentError: Error, LocalizedError, Equatable {
    case tooManyFiles
    case fileTooLarge(String)
    case totalTooLarge
    case unsupported(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles: return "单次最多添加 5 个附件"
        case .fileTooLarge(let name): return "附件过大：\(name)"
        case .totalTooLarge: return "附件总大小超过 20 MB"
        case .unsupported(let name): return "暂不支持该附件类型：\(name)"
        case .unreadable(let name): return "无法读取附件：\(name)"
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
        return try sizedAttachments.map { attachment, actualSize in
            guard actualSize <= maxFileBytes else {
                throw RAGAttachmentError.fileTooLarge(attachment.filename)
            }
            switch attachment.handling {
            case .textContext:
                guard let text = textContent(for: attachment) else {
                    throw RAGAttachmentError.unreadable(attachment.filename)
                }
                return RAGAttachmentContext(
                    attachmentID: attachment.id,
                    filename: attachment.filename,
                    content: String(text.prefix(maxCharactersPerFile))
                )
            case .vision:
                guard let data = try? Data(contentsOf: attachment.localURL), !data.isEmpty else {
                    throw RAGAttachmentError.unreadable(attachment.filename)
                }
                return RAGAttachmentContext(
                    attachmentID: attachment.id,
                    filename: attachment.filename,
                    content: "图片附件：\(attachment.filename)",
                    imageData: data,
                    contentType: attachment.contentType
                )
            case .unsupported:
                throw RAGAttachmentError.unsupported(attachment.filename)
            }
        }
    }

    private func textContent(for attachment: RAGComposerAttachment) -> String? {
        if attachment.contentType == "application/pdf" || attachment.localURL.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: attachment.localURL) else { return nil }
            return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        }
        guard let data = try? Data(contentsOf: attachment.localURL), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode)
    }
}
