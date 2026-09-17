import Foundation

/// Filtered development diagnostics. Normal app activity stays out of the console.
public enum LogStore {
    private static let formatter = ISO8601DateFormatter()

    public static func log(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        let message = message()
        guard message.hasPrefix("xdz.") || message.hasPrefix("export:") else { return }

        let tag = file.components(separatedBy: "/").last ?? file
        let stamp = formatter.string(from: Date())
        print("[GIFBloom] [\(stamp)] [\(tag):\(line)] \(message)")
        #endif
    }
}
