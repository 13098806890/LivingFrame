import Foundation

/// 调试日志：追加写入沙盒日志文件，可在设置页导出分析
public enum LogStore {
    private static let lock = NSLock()
    private static let maxEntries = 2000
    /// ISO8601DateFormatter 创建开销大，全局复用（写日志在锁内，线程安全）
    private static let formatter = ISO8601DateFormatter()
    /// 复用文件句柄，避免每次写日志都打开/关闭文件（抠图热循环里每帧都会写）
    private static var handle: FileHandle?

    public static var logURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("livingframe.txt")
    }

    public static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let tag = file.components(separatedBy: "/").last ?? file
        let stamp = formatter.string(from: Date())
        let entry = "[\(stamp)] [\(tag):\(line)] \(message)"

        // Live Photo 导出失败时需要从 Xcode 控制台直接复制完整链路。
        // 其他日志仍只写入文件，避免普通操作持续刷屏。
        #if DEBUG
        if message.hasPrefix("xdz.livephoto") || message.hasPrefix("export:") {
            print("[LivingFrame] \(entry)")
        }
        #endif

        lock.lock()
        defer { lock.unlock() }
        guard let handle = ensureHandle() else { return }
        handle.seekToEndOfFile()
        handle.write((entry + "\n").data(using: .utf8)!)
    }

    /// 惰性打开日志句柄（文件不存在时先创建），只打开一次
    private static func ensureHandle() -> FileHandle? {
        if let handle { return handle }
        let url = logURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let newHandle = try? FileHandle(forWritingTo: url) else { return nil }
        newHandle.seekToEndOfFile()
        handle = newHandle
        return newHandle
    }

    public static func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: logURL)
    }

    /// 在后台线程清理日志，避免关闭文件句柄和删除日志文件阻塞设置页。
    public static func clearAsync() async {
        await Task.detached(priority: .utility) {
            LogStore.clear()
        }.value
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
