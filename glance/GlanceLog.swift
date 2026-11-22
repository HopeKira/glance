//
//  GlanceLog.swift
//  glance
//
//  极简诊断日志：把关键动作（注入成功/失败、权限状态）追加到 ~/Library/Logs/Glance.log。
//  只写固定文案，不写密码、不写人脸数据。
//

import Foundation

/// 诊断日志：所有写入都串行化到专用 GCD queue，天然线程安全，
/// 可从后台线程调用。显式标注 nonisolated 以满足 Swift 6 并发检查。
nonisolated enum GlanceLog {
    private static let queue = DispatchQueue(label: "com.imanity.glance.v2.log")

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return base.appendingPathComponent("Logs/Glance.log")
    }

    static func write(_ message: String) {
        let line = "[\(Date().formatted(date: .numeric, time: .standard))] \(message)\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
