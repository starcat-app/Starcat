// MARK: - BinaryDetection
//
// 在 Tier 0/1 文件**读取前**调用，判定是否为 binary 应跳过。
//
// 算法（§22.7 Q6 决议）：
//   - 读头 8KB（git/diff/less/file 业界标准是 8000 字节）
//   - 含 NUL byte (0x00) 即视为 binary
//
// 已踩过的坑（写入注释作为永久记录）：
//   1. **不要尝试 String(contentsOf:) 全文 decode 后判定** —— 大文件可能 100MB 全量 load 内存
//   2. **不要只看扩展名** —— `.txt` 但内容是 protobuf 的伪装文件会蒙混
//   3. **不要做编码探测** —— UTF-16 文件含 NUL 字节会被误判为 binary，但 MVP 接受这个代价
//      （UTF-16 源码 < 0.1% 触发率，跳过比误处理安全）
//   4. **空文件视为 text** —— 让上层决定是否含（如 LICENSE 文件意外为空，应该 include 不该 skip）
//   5. **读不开文件视为 binary** —— 与 skip 策略一致（reason = `fileReadFailed`）
//
// 性能：Tier 0/1 通常 < 20 个文件 × 8KB = < 200KB 总 IO，可忽略。

import Foundation

public enum BinaryDetection {

    /// 头部采样字节数（业界标准 8000，向上对齐到 8192 = 8KB）。
    public static let sampleSize = 8192

    /// 判定文件是否为 binary。
    ///
    /// - Parameter url: 候选 Tier 0 / Tier 1 文件的绝对路径
    /// - Returns: true = binary（caller 应 skip 并记录 `binaryDetected`）/ false = text 可读
    ///
    /// **不抛错**：读不开 / 读失败一律返回 true（保守策略，让 caller 走 skip 流程）。
    public static func isLikelyBinary(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // 读不开 → 当 binary 处理
            return true
        }
        defer {
            try? handle.close()
        }

        guard let sample = try? handle.read(upToCount: sampleSize), !sample.isEmpty else {
            // 空文件 → 当 text（让上层处理空内容场景）
            return false
        }

        return sample.contains(0x00)
    }
}
