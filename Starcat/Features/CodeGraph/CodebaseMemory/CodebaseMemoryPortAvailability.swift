//
//  CodebaseMemoryPortAvailability.swift
//  Starcat
//
//  CodebaseMemory UI 端口占用检查。
//
//  100% 对齐 Starcat/Features/MCP/StarcatMCPPortAvailability.swift 的 POSIX bind()
//  探测策略：在真正启动 Process 前, 用 socket(AF_INET) + bind(127.0.0.1:<port>)
//  做一次同步预检, 避免把 "Address already in use" 留给用户看。
//
//  重要：必须设置 SO_REUSEADDR, 与 codebase 二进制内部分配行为对齐。

import Darwin
import Foundation

enum CodebaseMemoryPortAvailability {
    /// 返回 nil 表示当前端口可绑定；返回字符串表示可直接展示给用户的友好错误。
    ///
    /// 设置 `SO_REUSEADDR`：与 NWListener 默认行为对齐, 避免 TIME_WAIT 状态下误报。
    /// 真正被其他进程 `listen()` 占用时, `bind()` 仍会返回 EADDRINUSE,
    /// 不影响"发现已有监听者"的目的。
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

        if result == 0 {
            return nil
        }

        if errno == EADDRINUSE {
            return String(format: "Port %d is already in use", port)
        }
        return "Port check failed"
    }
}
