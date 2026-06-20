//
//  StarcatMCPPortAvailability.swift
//  Starcat
//
//  MCP Service 端口占用检查。
//
//  Starcat 的 MCP endpoint 固定监听 127.0.0.1，本文件只服务这个本机端口场景：
//  在真正启动 Network.framework listener 前，用 POSIX bind 做一次同步预检，
//  这样设置页能给出用户可读的错误，而不是暴露系统底层的 "Address already in use"。
//

import Darwin
import Foundation

enum StarcatMCPPortAvailability {
    /// 返回 nil 表示当前端口可绑定；返回字符串表示可直接展示给用户的友好错误。
    ///
    /// 这里不设置 `SO_REUSEADDR`：占用检查的目标是发现已有监听者，如果允许地址复用，
    /// 某些系统状态下会把“已有人在用”误判为“可用”。
    static func unavailableMessage(for port: Int) -> String? {
        guard (1024...65_535).contains(port) else {
            return String(format: String.l10n("settings.mcp.port.error.invalidFormat"), port)
        }

        let socketDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketDescriptor >= 0 else {
            return String.l10n("settings.mcp.port.error.checkFailed")
        }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socketDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            return nil
        }

        if errno == EADDRINUSE {
            return String(format: String.l10n("settings.mcp.port.error.inUseFormat"), port)
        }
        return String.l10n("settings.mcp.port.error.checkFailed")
    }
}
