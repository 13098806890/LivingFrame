import Foundation

/// 画布旋转的磁吸规则：接近 30° 的倍数时吸附，否则保持用户的连续输入。
public enum RotationSnapPolicy {
    public static let increment = Double.pi / 6
    public static let tolerance = Double.pi / 60

    public static func snapped(
        _ angle: Double,
        increment: Double = RotationSnapPolicy.increment,
        tolerance: Double = RotationSnapPolicy.tolerance
    ) -> Double {
        guard angle.isFinite, increment.isFinite, increment > 0,
              tolerance.isFinite, tolerance >= 0 else {
            return angle
        }

        let nearest = (angle / increment).rounded() * increment
        return abs(angle - nearest) <= tolerance ? nearest : angle
    }
}
