import Foundation

/// 导出帧率选项由工程中动态素材的最高实际帧率决定。
public enum ExportFPSPolicy {
    /// 常用帧率预设；素材的非标准最高帧率会额外加入选项。
    public static let presets: [Double] = [10, 15, 30, 60]

    public static func availableOptions(
        maxSourceFPS: Double,
        presets: [Double] = ExportFPSPolicy.presets
    ) -> [Double] {
        guard maxSourceFPS.isFinite, maxSourceFPS > 0 else { return [] }

        var options = presets.filter { value in
            value.isFinite && value > 0 && value <= maxSourceFPS + 0.01
        }
        if !options.contains(where: { abs($0 - maxSourceFPS) < 0.01 }) {
            options.append(maxSourceFPS)
        }
        return Array(Set(options)).sorted()
    }
}
