//
//  CodebaseMemoryPortAvailability.swift
//  Starcat
//
//  App Store 内置 CodebaseMemory UI 的端口占用检查。
//
//  Direct 外部 0.10.8+ 复用账户级共享 daemon，不走此检查；内置 0.8.1
//  仍需在真正启动 Process 前确认随机端口可以绑定。
//

import Darwin
import Foundation

enum CodebaseMemoryPortAvailability {
    /// 返回 nil 表示当前端口可绑定；返回字符串表示该端口不可用。
    static func unavailableMessage(for port: Int) -> String? {
        guard (1024...65_535).contains(port) else {
            return String(format: "Port %d out of range", port)
        }

        let socketDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketDescriptor >= 0 else {
            return "Port check failed"
        }
        defer { close(socketDescriptor) }

        var reuseAddr: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddr,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        if result == 0 { return nil }
        if errno == EADDRINUSE {
            return String(format: "Port %d is already in use", port)
        }
        return "Port check failed"
    }
}
