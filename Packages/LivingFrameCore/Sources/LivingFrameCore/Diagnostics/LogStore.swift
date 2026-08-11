import Foundation

/// 调试日志：追加写入沙盒日志文件，可在设置页导出分析
public enum LogStore {
    private static let lock = NSLock()
    private static let maxEntries = 2000

    public static var logURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("livingframe.txt")
    }

    public static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let tag = file.components(separatedBy: "/").last ?? file
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] [\(tag):\(line)] \(message)"
        lock.lock()
        defer { lock.unlock() }
        do {
            let url = logURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write((entry + "\n").data(using: .utf8)!)
                try? handle.close()
            } else {
                try (entry + "\n").data(using: .utf8)?.write(to: url)
            }
        } catch {
            // 日志失败不影响功能
        }
    }

    public static func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: logURL)
    }

    /// 截断为最近 N 行，防止日志无限膨胀
    public static func trimIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
        guard lines.count > maxEntries else { return }
        let tail = lines.suffix(maxEntries).joined(separator: "\n") + "\n"
        try? tail.data(using: .utf8)?.write(to: logURL)
    }
}
