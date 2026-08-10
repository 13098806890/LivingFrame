# LivingFrame（活影）

> 哈利波特风格的「动态照片」制作工具 —— 从视频 / Live Photo 抠出人物，多元素合成 + 音轨，导出动图 / 视频，用 Widget 展示。

**纯本地工具类 App**：无联网、无账号、无素材下载，全部处理在设备端完成。

## 功能

- 🪄 **人物抠图**：Vision 实例分割（iOS 17+），视频 / Live Photo → 透明素材
- 🎞️ **多元素合成**：多个素材同画布，位置 / 缩放 / 旋转 / 层级 / 出现时段
- 🎵 **音轨**：自动提取视频音频，时间轴摆放、音量、淡入淡出
- ✨ **魔法模板**：魔法画框 / 金角海报 / 魔杖辉光 / 纯净黑幕，一键套用
- 📤 **导出**：GIF（通用） / HEVC-alpha（透明） / H.264（回退）
- 🧩 **Widget**：作品静态帧展示（WidgetKit 限制，不支持动图播放）
- 🌍 **国际化**：简体中文 + 15 种语言（详见下）

## 国际化

开发语言为简体中文（源码字符串即 key），随 App 与 Widget 打包 16 种语言：

| 语言 | 代码 | | 语言 | 代码 |
|---|---|---|---|---|
| 简体中文（源） | zh-Hans | | 葡萄牙语（巴西） | pt-BR |
| 繁体中文 | zh-Hant | | 俄语 | ru |
| 英语 | en | | 阿拉伯语 | ar |
| 日语 | ja | | 泰语 | th |
| 韩语 | ko | | 越南语 | vi |
| 法语 | fr | | 印尼语 | id |
| 德语 | de | | 土耳其语 | tr |
| 西班牙语 | es | | 印地语 | hi |
| 意大利语 | it | | | |

- 翻译文件：`LivingFrame/Localization/<lang>.lproj/{Localizable,InfoPlist}.strings`
- App 的 `Localization/` 目录由 Xcode 16 同步组自动编入 target；Widget 通过 PBXVariantGroup 引用同一批文件
- fallback 规则：未覆盖语言回退到开发语言（zh-Hans，即源码中文）
- App 显示名（CFBundleDisplayName）与 Widget 名称随语言切换

## 架构

```
┌─ UI 层（SwiftUI，iOS）────────────────────────────┐
│  4 Tab：素材库 / 编辑 / 作品 / 设置 + 4 Sheet      │
├─ LivingFrameCore（SPM 包，双平台）─────────────────┤
│  Models · Segmentation · Composition · Audio ·     │
│  Export · Templates · Storage                      │
│  （不 import UIKit/AppKit，macOS 14+ 可复用）       │
├─ Widget（静态帧，读 App Group 共享容器）────────────┤
└───────────────────────────────────────────────────┘
```

详细设计见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 工程结构

```
LivingFrame.xcodeproj        iOS 工程（App + Widget target）
Packages/LivingFrameCore/    SPM 核心包（全部业务逻辑）
  Sources/LivingFrameCore/
    Models/                  数据模型（Codable）
    Segmentation/            抠图管线 + 帧缓存
    Composition/             CoreImage 统一渲染器
    Audio/                   音频提取 / 实时预览 / 离线混音
    Export/                  GIF / HEVC-alpha / H.264 导出
    Templates/               内置模板 + 矢量装饰绘制
    Storage/                 作品持久化 + App Group 帧
LivingFrame/                 SwiftUI 页面层
  Localization/              16 语言 .strings（App 同步组）
LivingFrameWidget/           Widget Extension
```

## 构建

```bash
# Core 包自测（macOS）
cd Packages/LivingFrameCore && swift build

# iOS 工程（模拟器）
xcodebuild -project LivingFrame.xcodeproj \
  -scheme LivingFrame \
  -destination 'generic/platform=iOS Simulator' \
  -CODE_SIGNING_ALLOWED=NO build
```

要求：Xcode 16+，iOS 17+ 部署目标。

## 真机部署注意

- 代码签名：需在 Xcode 中选择你自己的 Team（`DEVELOPMENT_TEAM`）
- Widget / App Group：在 Capabilities 中确认 `group.com.livingframe.shared` 已被签名生效；模拟器上 App Group 容器可能不可达，Widget 会显示占位图
- HEVC-alpha 编码器：模拟器不支持，导出透明视频必须真机验证
- bundle id：App 为 `com.livingframe.app`，Widget 为 `com.livingframe.app.widget`（必须为前缀关系）

## 技术要点

- 抠图：`VNGeneratePersonInstanceMaskRequest` + `generateMaskedImage(ofInstances:from:croppedToInstancesExtent:)`，不裁剪保持帧尺寸一致
- 渲染：`CompositionRenderer` 统一管线，预览与导出共用同一份代码（所见即所得）
- 缓存：抠图结果落地为逐帧 PNG 序列（Caches），按需加载，支持清理
- 音轨双路径：预览用 `AVAudioEngine` 实时播放（<200ms 误差），导出用 `AVMutableComposition` 离线精确混音
- 本地化：SwiftUI `Text()` 自动按 LocalizedStringKey 查表；Core 层经 `NSLocalizedString`（Bundle.main）复用同一份资源
- Widget 边界：WidgetKit 无媒体播放能力，只展示静态帧，点击打开 App 看动态
