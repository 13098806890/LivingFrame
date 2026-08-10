import Foundation

/// 音轨片段：一段音频素材在时间轴上的摆放
public struct AudioClip: Identifiable, Codable, Equatable {
    public var id: UUID
    /// 音频素材引用（SegmentedClip.id，即提取出的 m4a 所在目录）
    public var sourceID: String
    /// 时间轴位置（秒）
    public var startTime: TimeInterval
    /// 播放时长（秒，可小于素材长度 = 截取）
    public var duration: TimeInterval
    public var volume: Float
    public var fadeIn: TimeInterval
    public var fadeOut: TimeInterval
    public var loop: Bool

    public init(
        id: UUID = UUID(),
        sourceID: String,
        startTime: TimeInterval = 0,
        duration: TimeInterval = 3,
        volume: Float = 1,
        fadeIn: TimeInterval = 0,
        fadeOut: TimeInterval = 0,
        loop: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.startTime = startTime
        self.duration = duration
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.loop = loop
    }
}
