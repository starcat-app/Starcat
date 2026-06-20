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
//  重要：必须设置 SO_REUSEADDR，与 NWListener 行为对齐。
//  NWListener 默认开启 SO_REUSEADDR，会跳过 TIME_WAIT 状态的 socket；
//  如果预检不设 SO_REUSEADDR，会把"刚退出的 listener 还在 TIME_WAIT"
//  误判为"端口被占用"，重启场景下报"端口被占用"实际 NWListener 自己是能绑上的。
//

import Darwin
import Foundation

enum StarcatMCPPortAvailability {
    /// 返回 nil 表示当前端口可绑定；返回字符串表示可直接展示给用户的友好错误。
    ///
    /// 设置 `SO_REUSEADDR`：与 NWListener 默认行为对齐，避免 TIME_WAIT 状态下
    /// 误报。真正被其他进程 `listen()` 占用时，`bind()` 仍会返回 EADDRINUSE，
    /// 不影响"发现已有监听者"的目的。
    static func unavailableMessage(for port: Int) -> String? {
        guard (1024...65_535).contains(port) else {
            return String(format: String.l10n("settings.mcp.port.error.invalidFormat"), port)
        }

        let socketDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketDescriptor >= 0 else {
            return String.l10n("settings.mcp.port.error.checkFailed")
        }
        defer { close(socketDescriptor) }

        // 与 NWListener 行为对齐：跳过 TIME_WAIT 的 socket（NWListener 默认开启 SO_REUSEADDR）。
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
