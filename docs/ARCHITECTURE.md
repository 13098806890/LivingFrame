# LivingFrame 架构清单（Architecture）

> 活文档：随代码演进同步更新。状态：**设计阶段，待确认后开工**。

## 1. 目标与约束

### 产品定位
- 名称：LivingFrame（活影）—— 哈利波特风格"动态照片"制作工具
- 定位：**纯本地工具类 App**，无联网、无账号、无素材下载，全部处理在设备端完成（隐私/离线是差异化卖点）
- 核心链路：视频/Live Photo → 抠出人物 → 多元素合成 + 音轨 → 导出动图/视频 → Widget 展示

### 平台与版本
- 首发：iOS 17+（iPhone / iPad）
- 架构预留：macOS 14+（已验证底层技术全支持，见 §8.1）
- 最低系统版本约束来源：`VNGeneratePersonInstanceMaskRequest`（iOS 17 / macOS 14）

### 硬性约束
- Core 层不 import `UIKit` / `AppKit` / `SwiftUI`（跨平台 + 可单测）
- 内置模板，无网络素材入口
- 抠图性能预期：10s 视频约 1–3 分钟（720p 逐帧），必须后台队列 + 可取消 + 进度回调

## 2. 工程结构

```
LivingFrame/
├── Packages/
│   └── LivingFrameCore/          # SPM 包：全部业务逻辑（双平台、可单测）
├── LivingFrame/                  # iOS App target（SwiftUI，仅 UI + 系统入口）
├── LivingFrameWidget/            # Widget Extension（静态帧）
├── LivingFrameMac/               # 未来 macOS target（复用 Core + 大部分页面）
├── docs/
│   └── ARCHITECTURE.md           # 本文档
```

**依赖方向（禁止反向依赖）**
```
LivingFrameApp ──→ LivingFrameCore
LivingFrameWidget ──→ LivingFrameCore（仅 FrameStore / 模型，只读）
LivingFrameMac（未来）──→ LivingFrameCore
```

## 3. 模块划分

### LivingFrameCore（SPM Package，目录即模块）
| 目录 | 职责 | 依赖 |
|---|---|---|
| `Models/` | 全部数据模型（Codable） | 仅 Foundation/CoreGraphics |
| `Segmentation/` | 视频抠图管线、帧缓存 | Models |
| `Composition/` | CoreImage 渲染器（预览/导出共用） | Models |
| `Audio/` | 音频提取、实时预览引擎、离线混音 | Models |
| `Export/` | HEVC-alpha / H.264 / GIF 导出 | Models, Composition |
| `Templates/` | 内置模板目录、矢量装饰绘制 | Models, Composition |
| `Storage/` | 作品持久化、App Group 共享帧 | Models |
| `Resources/` | 内置 PNG 装饰资产（SPM 资源 bundle） | — |

### App 层（iOS target）
| 目录 | 职责 |
|---|---|
| `App/` | App 入口、AppState（@MainActor ObservableObject） |
| `Views/` | 4 Tab + 4 Sheet 全部页面（见 §5 页面布局） |
| `Views/Components/` | 通用 UI 组件（按钮样式、空状态、卡片） |
| `Resources/` | Assets.xcassets（App 图标、AccentColor） |

**依赖规则**
- Views 只依赖 AppState 与 Core 的公开 API，不直接碰 AVFoundation/Vision
- 唯一例外：素材选择入口（PhotosPicker / 未来 FileImporter），封装在 `Views/Library` 内
- AppState 负责编排 Core 服务，是唯一"知道一切"的对象（页面间只通过它通信）

## 4. 文件清单（职责 + 依赖方向）

### LivingFrameCore
| 文件 | 职责 | 依赖 |
|---|---|---|
| `Models/Composition.swift` | CanvasSpec / ElementTransform / Composition / CompositionElement / BackgroundPreset | — |
| `Models/AudioClip.swift` | AudioClip（音轨片段） | — |
| `Models/SegmentedClip.swift` | 抠图结果（帧序列元信息 + 加载） | — |
| `Models/WorkItem.swift` | 作品快照（JSON + 封面） | Composition |
| `Models/MagicTemplate.swift` | 模板与装饰类型定义（含 ExportFormat） | — |
| `Segmentation/VisionPersonSegmenter.swift` | 单帧实例掩码抠图（VNGeneratePersonInstanceMaskRequest） | — |
| `Segmentation/VideoSegmentationPipeline.swift` | 逐帧读流→抠图→PNG 缓存→音频提取，进度/取消 | VisionPersonSegmenter, AudioExtractor |
| `Segmentation/FrameCache.swift` | 磁盘帧缓存注册/清理 | SegmentedClip |
| `Audio/AudioExtractor.swift` | 视频→m4a 提取（AVAssetReader） | — |
| `Audio/AudioPreviewEngine.swift` | 实时播放音轨（AVAudioEngine，与预览时钟对齐） | AudioClip |
| `Audio/OfflineAudioMixer.swift` | 离线混音（AVMutableComposition + AVAudioMix）→ m4a | AudioClip |
| `Composition/CompositionRenderer.swift` | CIImage 逐层合成（背景/装饰/人物/特效）→ CGImage / CVPixelBuffer | 全部 Models, Templates |
| `Export/VideoExporter.swift` | AVAssetWriter：HEVC-alpha（回退 H.264）、音视频合并 | CompositionRenderer, OfflineAudioMixer |
| `Export/GIFExporter.swift` | ImageIO 逐帧 GIF | CompositionRenderer |
| `Templates/TemplateCatalog.swift` | 内置模板注册表（纯代码定义） | MagicTemplate |
| `Templates/VectorDecorations.swift` | 画框/金角/光斑等矢量装饰绘制（CoreGraphics → CGImage） | — |
| `Storage/WorksStore.swift` | 作品读写（Documents/Works/{id}/） | WorkItem |
| `Storage/FrameStore.swift` | App Group 静态帧读写（Widget 用） | — |

### App 层
| 文件 | 职责 |
|---|---|
| `App/LivingFrameApp.swift` | @main，注入 AppState |
| `App/AppState.swift` | 全局状态与编排（见 §6 状态设计） |
| `Views/MainTabView.swift` | 4 Tab 容器 |
| `Views/Library/LibraryView.swift` | 素材库：选择/抠图进度/素材网格（含音频标记） |
| `Views/Editor/EditorView.swift` | 编辑页：画布 + 双轨时间轴 + 检查器 + 工具栏 |
| `Views/Editor/CanvasView.swift` | 预览渲染 + 拖拽/播放控制 |
| `Views/Editor/TimelineView.swift` | 视频元素轨 + 音频轨双轨时间轴 |
| `Views/Editor/ElementInspectorView.swift` | 选中对象检查器（视频元素/音频段分派） |
| `Views/Editor/TemplatePickerView.swift` | Sheet：内置模板选择（实时缩略图） |
| `Views/Editor/EffectPickerView.swift` | Sheet：魔法特效选择 |
| `Views/Works/WorksView.swift` | 作品网格 + 重编辑/分享 |
| `Views/Works/WidgetSetupView.swift` | Sheet：设为 Widget 画面 |
| `Views/Export/ExportView.swift` | Sheet：格式/帧率/进度/分享/存相册 |
| `Views/Settings/SettingsView.swift` | 导出默认、抠图质量、隐私说明、关于 |
| `Views/Components/*` | MagicButtonStyle / EmptyStateView / SectionCard |

### Widget 层
| 文件 | 职责 |
|---|---|
| `LivingFrameWidget/LivingFrameWidget.swift` | WidgetBundle + StaticConfiguration + TimelineProvider（读 FrameStore） |

## 5. 页面布局（4 Tab + 4 Sheet）

```
主框架：Tab 素材库 | 编辑 | 作品 | 设置

Tab 1 素材库   LibraryView
  ├─ 顶部入口：选择视频 / Live Photo（PhotosPicker，可多选）
  ├─ 抠图进度卡片（进度条 + 取消 + 剩余帧数）
  └─ 素材网格（缩略图 / 时长 / 帧数 / 音轨标记 ♪；滑动删除；空状态引导）

Tab 2 编辑     EditorView（三段式）
  ├─ 画布预览     CanvasView：播放/暂停、时间显示、拖拽元素=移动
  ├─ 时间轴      TimelineView：双轨横滚
  │     ├─ 视频元素轨：元素起止条（拖动调节时段）
  │     └─ 音频轨：音频段（拖动位置/截取/音量滑块）
  └─ 检查器       ElementInspectorView：选中视频元素→变换（缩放/旋转/层级/时段）；
                   选中音频段→音量/淡入淡出/循环
  工具栏：模板 | 特效 | 添加素材 | 导出

Tab 3 作品     WorksView
  ├─ 作品网格（封面/名称/日期/格式标签）
  └─ 详情操作：重新编辑 / 重新导出 / 分享 / 设为 Widget 画面（Sheet）

Tab 4 设置     SettingsView
  ├─ 导出默认格式（GIF / HEVC-alpha）、帧率
  ├─ 抠图分辨率（720p / 1080p）、清理缓存
  └─ 隐私说明（全部本地处理）、关于

Sheet 模板选择  TemplatePickerView：内置模板卡片（实时渲染预览，标注"内置·离线可用"）
Sheet 特效选择  EffectPickerView：光效/粒子列表 → 附加到元素
Sheet 导出      ExportView：格式/帧率/时长 → 进度 → 分享 / 存相册 / 设为 Widget
Sheet Widget 设置 WidgetSetupView：选作品 + 静态帧限制说明
```

## 6. 状态设计（AppState）

```swift
// @MainActor，唯一编排层；页面通过 @EnvironmentObject 访问
@Published var clips: [SegmentedClip]          // 抠图素材
@Published var composition: Composition?       // 当前编辑工程
@Published var selectedElementID: UUID?        // 编辑器选中项（元素/音频段）
@Published var currentTime: Double             // 预览时钟（秒）
@Published var isPlaying: Bool
@Published var isSegmenting / segmentationProgress
@Published var isExporting / exportProgress / exportResultURL
@Published var works: [WorkItem]
@Published var sheetState（模板/特效/导出/Widget 设置）
```

**关键数据流**
1. **抠图流**：PhotosPicker → movie URL → `VideoSegmentationPipeline`（后台：逐帧抠图 → PNG 序列 + m4a 音频）→ 注册 FrameCache → AppState 追加 clip + 自动加入画布
2. **预览流**：Timer(1/30) 推进 currentTime → `CompositionRenderer` 渲染帧 → CanvasView；`AudioPreviewEngine` 按同一时钟调度音频
3. **导出流**：Composition + AudioClips → 视频帧 CI 渲染写 AVAssetWriter 视频轨 + `OfflineAudioMixer` 混音写音频轨 → 输出文件 → 分享/存相册/存作品
4. **Widget 流**：导出完成或编辑时 → 渲染首帧 → `FrameStore` 写入 App Group → Widget TimelineProvider 读取展示

## 7. 数据模型（核心字段）

```swift
struct CanvasSpec: Codable { var width, height: CGFloat }

struct ElementTransform: Codable {
    var position: CGPoint      // 画布坐标系（CI 左下原点，y 向上）
    var scale: CGFloat         // 相对素材原始尺寸
    var rotation: CGFloat      // 弧度
}

enum ElementKind: Codable {
    case clip(clipID: String)           // 引用抠图素材
    case decoration(decorationID: String) // 内置矢量装饰
    case effect(effectID: String)       // 魔法特效
}

struct CompositionElement: Identifiable, Codable {
    var id: UUID
    var kind: ElementKind
    var name: String
    var transform: ElementTransform
    var zIndex: Int                    // 层级，大者在上
    var startTime, endTime: TimeInterval // 时间轴出现/消失
}

struct AudioClip: Identifiable, Codable {
    var id: UUID
    var sourceID: String               // 音频素材引用（提取出的 m4a）
    var startTime: TimeInterval        // 时间轴位置
    var duration: TimeInterval         // 播放时长（可小于素材长度=截取）
    var volume: Float
    var fadeIn, fadeOut: TimeInterval
    var loop: Bool
}

struct BackgroundPreset: Codable {
    var kind: Kind                     // .clear / .solid / .gradient
    var topColor, bottomColor: String  // hex
}

struct Composition: Identifiable, Codable {
    var id: UUID
    var name: String
    var canvas: CanvasSpec
    var duration: TimeInterval
    var fps: Double
    var elements: [CompositionElement]
    var audioClips: [AudioClip]
    var background: BackgroundPreset
    var templateID: String?
}

struct SegmentedClip: Identifiable {   // 运行时缓存，非 Codable
    var id: String
    var name: String
    var fps: Double; var frameCount: Int
    var width, height: Int
    var folderURL: URL                 // PNG 序列目录
    var audioURL: URL?                 // 提取的 m4a
    var duration: TimeInterval
}

struct WorkItem: Codable, Identifiable {
    var id: UUID; var name: String
    var createdAt: Date
    var composition: Composition       // 完整快照，可重新编辑
    var posterData: Data               // 封面 PNG
    var format: ExportFormat
}

struct MagicTemplate: Identifiable {   // 代码内置，非用户数据
    var id: String; var name: String; var tagline: String
    var canvasPreset: CanvasSpec?
    var background: BackgroundPreset?
    var decorations: [DecorationPreset]    // 装饰摆放
    var effectPresets: [String]
    var elementLayouts: [ElementLayoutPreset] // 人物元素默认摆放
}

enum ExportFormat: String, Codable { case gif, hevcAlpha, h264 }
```

## 8. 关键决策记录（ADR）

### 8.1 双平台可行性（已验证）
| 能力 | API | iOS | macOS |
|---|---|---|---|
| 人物实例抠图 | `VNGeneratePersonInstanceMaskRequest` | 17+ | 14.0+ |
| 音视频读写 | AVFoundation 全链路 | 全 | 全 |
| 实时音频 | AVAudioEngine | 全 | 全 |
| HEVC-alpha | `AVVideoCodecType.hevcWithAlpha` | 13+ | 10.15+ |
| GIF | ImageIO | 全 | 全 |
| Widget | WidgetKit | 14+ | 11+ |

→ 核心链路单一代码双平台，无分支差异。

### 8.2 渲染统一管线（CoreImage）
- 预览与导出共用 `CompositionRenderer`，保证所见即所得
- 创作空间 = CI 左下原点坐标（y 向上），UI 层做坐标换算，渲染层零翻转 hack
- `CIImage(cgImage:)` 与 `CIContext.createCGImage` 往返保持图像正向，缓冲行序一致
- 素材帧（PNG）经 CI 输出，天然 premultiplied alpha，符合 HEVC-alpha 编码要求

### 8.3 抠图缓存策略
- 素材落地为**逐帧 PNG 序列**（Caches 目录），而非内存数组（300 帧 RGBA ≈ 1.2GB 不可行）
- 渲染时按需加载单帧，编辑/导出共用
- 帧尺寸一致：`generateMaskedImageOfInstances(allInstances, cropToInstancesExtent: false)`，保证元素位置稳定不抖动

### 8.4 音轨双路径
- 预览：`AVAudioEngine` + `AVAudioPlayerNode.scheduleSegment`，与视频预览时钟对齐（误差 <200ms，MVP 可接受）
- 导出：`AVMutableComposition` + `AVAudioMix` 离线混音（精确），随 AVAssetWriter 同步写入
- 同一 `AudioClip` 模型被两条路径消费

### 8.5 Widget 边界
- WidgetKit 无媒体播放能力 → Widget 只读 `FrameStore` 中的静态帧（App Group）
- 点击打开 App 查看动态效果；不承诺 Widget 内动画

### 8.6 模板资产策略
- 装饰优先**矢量绘制**（CoreGraphics → CGImage，体积 0、无限缩放、双平台复用）
- 复杂图案（羽毛笔、报纸版式）用 SPM Resources 内置 PNG
- 模板 = 纯代码定义，JSON 可序列化，便于未来本地模板扩展

### 8.7 Core 纯净层
- Core 不 import UIKit/AppKit/SwiftUI，类型只用 CGImage/CVPixelBuffer/AVFoundation/Vision/CoreImage/ImageIO
- 收益：可加 XCTest target；未来 macOS/visionOS 直接复用

## 9. 技术风险与回退方案

| 风险 | 影响 | 回退方案 |
|---|---|---|
| HEVC-alpha 编码器异常（macOS 12.3 有已知 pixelBufferPool 崩溃，关闭 temporal compression 规避） | 导出失败 | 自动回退 H.264（无透明）+ GIF |
| 预览 30fps 主线程 CI 渲染开销 | 卡顿 | 预览降分辨率渲染 / 渲染队列化 / 仅播放时渲染 |
| 长视频逐帧 PNG 磁盘占用 | 存储膨胀 | Caches 可被系统清理 + 设置页手动清理 |
| Vision 多人场景上限 4 人 | 多人抠不全 | MVP 单帧全员抠图，文档说明限制 |
| 帧内无人物（人物出画） | 空帧 | 跳过该帧，素材按实际帧数截断 |
| 模拟器无 HEVC-alpha 编码器 | 真机差异 | 导出必须真机验证 |

## 10. 实施顺序（开工里程碑）

1. **M1 工程骨架**：SPM Core 包 + iOS 工程 + Widget 空壳，全部编译通过
2. **M2 模型与存储**：全部 Codable 模型 + WorksStore + FrameStore
3. **M3 抠图链路**：VideoSegmentationPipeline 真机可跑，素材入库
4. **M4 渲染与编辑**：CompositionRenderer + 编辑页三段式 UI 完整可用
5. **M5 导出**：GIF → HEVC-alpha（含音频混音）→ 分享/存相册/存作品
6. **M6 模板与特效**：TemplateCatalog + 矢量装饰 + 模板页
7. **M7 Widget 收尾**：静态帧展示 + 设置页
8. **M8 打磨**：性能、空状态、隐私文案、图标

