import CoreGraphics

/// 与具体素材类型无关的撕边轮廓强度。
enum TornEdgeProfile: String, Sendable {
    case soft
    case fibrous
    case layered
}

/// 确定性的撕边路径生成器。
///
/// 同一组输入永远得到同一条路径，因此可安全用于动图、视频和导出，
/// 不会因为逐帧随机数产生边缘闪烁。
enum TornEdgeGeometry {
    static func offset(
        progress: CGFloat,
        profile: TornEdgeProfile,
        limit: CGFloat,
        seed: UInt64 = 0x7A11_CE5E_ED01
    ) -> CGFloat {
        let amplitude: CGFloat
        let coarseFrequency: CGFloat
        let mediumFrequency: CGFloat
        let fineFrequency: CGFloat
        switch profile {
        case .soft:
            amplitude = min(limit * 0.030, 15)
            coarseFrequency = 5
            mediumFrequency = 17
            fineFrequency = 43
        case .fibrous:
            amplitude = min(limit * 0.060, 34)
            coarseFrequency = 8
            mediumFrequency = 31
            fineFrequency = 97
        case .layered:
            amplitude = min(limit * 0.050, 28)
            coarseFrequency = 6
            mediumFrequency = 23
            fineFrequency = 71
        }

        // 多尺度固定噪声比正弦波更接近纸纤维断裂：大块缺口决定轮廓，
        // 中高频只负责毛边。端点收敛到 0，四条边能自然接合。
        let coarse = valueNoise(progress * coarseFrequency, seed: seed)
        let medium = valueNoise(progress * mediumFrequency, seed: seed &+ 0x9E37_79B9)
        let fine = valueNoise(progress * fineFrequency, seed: seed &+ 0xD1B5_4A32)
        let edgeEnvelope = min(min(progress / 0.045, (1 - progress) / 0.045), 1)

        // 少量尖锐裂口打破“均匀波浪”的塑料感。
        let notchPosition = progress * (profile == .fibrous ? 19 : 13)
        let notchIndex = Int(floor(notchPosition))
        let notchLocal = notchPosition - CGFloat(notchIndex)
        let notchStrength = unitHash(UInt64(max(notchIndex, 0)), seed: seed &+ 0xA24B_AED4)
        let notchShape = max(0, 1 - abs(notchLocal - 0.5) / 0.16)
        let notchDirection: CGFloat = unitHash(
            UInt64(max(notchIndex, 0)),
            seed: seed &+ 0xC13F_A9A9
        ) > 0.5 ? 1 : -1
        let notch = notchStrength > 0.70
            ? notchDirection * notchShape * amplitude * (profile == .fibrous ? 0.48 : 0.32)
            : 0

        return ((coarse * 0.58 + medium * 0.29 + fine * 0.13) * amplitude + notch) * max(edgeEnvelope, 0)
    }

    static func addLine(
        from start: CGPoint,
        to end: CGPoint,
        profile: TornEdgeProfile,
        segmentCount: Int? = nil,
        seed: UInt64 = 0x7A11_CE5E_ED01,
        in path: CGMutablePath
    ) {
        let normal = CGPoint(x: -(end.y - start.y), y: end.x - start.x)
        let length = max(hypot(normal.x, normal.y), 1)
        let defaultStep: CGFloat
        switch profile {
        case .soft: defaultStep = 12
        case .fibrous: defaultStep = 5
        case .layered: defaultStep = 8
        }
        let count = segmentCount ?? min(max(Int(length / defaultStep), 36), 240)
        for index in 1...count {
            let progress = CGFloat(index) / CGFloat(count)
            let baseX = start.x + (end.x - start.x) * progress
            let baseY = start.y + (end.y - start.y) * progress
            let amount = offset(
                progress: progress,
                profile: profile,
                limit: min(length * 0.18, 420),
                seed: seed
            )
            path.addLine(to: CGPoint(
                x: baseX + normal.x / length * amount,
                y: baseY + normal.y / length * amount
            ))
        }
    }

    static func addRect(
        _ rect: CGRect,
        profile: TornEdgeProfile,
        in path: CGMutablePath
    ) {
        let bottomLeft = CGPoint(x: rect.minX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let topLeft = CGPoint(x: rect.minX, y: rect.maxY)
        path.move(to: bottomLeft)
        addLine(from: bottomLeft, to: bottomRight, profile: profile, seed: 0xB071_0A11, in: path)
        addLine(from: bottomRight, to: topRight, profile: profile, seed: 0xA19F_2743, in: path)
        addLine(from: topRight, to: topLeft, profile: profile, seed: 0xC84D_5517, in: path)
        addLine(from: topLeft, to: bottomLeft, profile: profile, seed: 0xE213_8BC9, in: path)
        path.closeSubpath()
    }

    private static func valueNoise(_ position: CGFloat, seed: UInt64) -> CGFloat {
        let lower = Int(floor(position))
        let fraction = position - CGFloat(lower)
        let from = unitHash(UInt64(max(lower, 0)), seed: seed) * 2 - 1
        let to = unitHash(UInt64(max(lower + 1, 0)), seed: seed) * 2 - 1
        // smoothstep 保留撕裂转折，但不会出现锯齿式的机械尖角。
        let blend = fraction * fraction * (3 - 2 * fraction)
        return from + (to - from) * blend
    }

    private static func unitHash(_ index: UInt64, seed: UInt64) -> CGFloat {
        var value = index &+ seed &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return CGFloat(value & 0x00FF_FFFF) / CGFloat(0x00FF_FFFF)
    }
}
