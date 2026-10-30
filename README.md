# GIFBloom

GIFBloom 是一款面向 iPhone 的动态影像创作工具：从视频、Live Photo 或其他动态素材中提取人物，叠加背景、贴纸、文字和音轨，制作分层动态作品，并导出为 GIF、视频或 Live Photo。

项目内部工程名仍为 `LivingFrame`；面向用户的品牌名是 `GIFBloom`。

## 产品状态

- 平台：iOS 18+
- 当前 Xcode App target：Marketing Version `1.07` / Build `17`
- App Store Connect：最近一次记录的已发布基线为 `1.06` / Build `15`（2026-10-27）；提交前仍需核对实时状态
- 主分类：Photo & Video
- 处理方式：选中的媒体主要在设备端完成抠图、合成和导出；不需要账号，也没有应用自建后端、分析 SDK 或用户素材上传服务
- 注意：Photos/iCloud 可能按照系统权限和用户选择下载原始媒体，这不等于应用拥有独立的云端素材服务

## 功能

- **人物抠图**：将视频或 Live Photo 中的人物提取为动态透明素材；Core 层保留 Vision 人物实例与原始前景两条分割管线
- **多层合成**：在同一画布叠加多个动态素材，调整位置、缩放、旋转、图层顺序和时间轴区间
- **动态背景与素材**：支持照片、视频、Live Photo、GIF/APNG 等素材作为背景或画布内容
- **贴纸与文字**：提供表情、涂鸦、图形、品牌 Logo、水果等贴纸，并支持文字排版；部分贴纸支持面部跟踪
- **画布与效果**：支持画布背景、画框、视觉效果和拼接/分区创作
- **音轨**：从视频提取音频，在时间轴中调整起止时间、音量和淡入淡出；导出时进行离线混音
- **导出**：支持 GIF、透明 HEVC-alpha、普通 H.264 视频和 Live Photo；可预览规格与预计文件大小，并保存到 Photos 或分享
- **Pro 能力**：当前本地设置允许 Pro 用户将最长提取时长设为 15 秒；商店文案和订阅权益需与 1.07 提交 Build 对齐

## 本地化

App 当前包含 19 种界面语言：

| Locale | 语言 | Locale | 语言 |
|---|---|---|---|
| `zh-Hans` | 简体中文 | `zh-Hant` | 繁体中文 |
| `en` | 英语 | `ja` | 日语 |
| `ko` | 韩语 | `fr` | 法语 |
| `de` | 德语 | `es` | 西班牙语 |
| `it` | 意大利语 | `pt-BR` | 巴西葡萄牙语 |
| `id` | 印尼语 | `ru` | 俄语 |
| `th` | 泰语 | `tr` | 土耳其语 |
| `vi` | 越南语 | `hi` | 印地语 |
| `ar` | 阿拉伯语 | `af` | 南非荷兰语 |
| `sw` | 斯瓦希里语 |  |  |

本地化文件位于 `LivingFrame/Localization/<locale>.lproj/`，包括 `Localizable.strings` 和 `InfoPlist.strings`。新增斯瓦希里语（东非）和南非荷兰语（南非）；未覆盖的系统语言回退到英语。日期使用系统地区格式，订阅价格由 StoreKit 按 App Store storefront 本地化。

## 架构

```text
┌─ UI 层（SwiftUI，iOS）────────────────────────────┐
│  素材库 / 编辑 / 作品 / 设置 + 多个 Sheet           │
├─ LivingFrameCore（Swift Package，双平台）─────────┤
│  Models · Segmentation · Composition · Audio       │
│  Export · Templates · FaceTracking · Storage       │
│  （不 import UIKit/AppKit，macOS 14+ 可复用）       │
└───────────────────────────────────────────────────┘
```

详细设计见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 工程结构

```text
LivingFrame.xcodeproj        iOS 工程（App target）
Packages/LivingFrameCore/    Swift Package（核心业务逻辑）
  Sources/LivingFrameCore/
    Models/                  Codable 数据模型
    Segmentation/            抠图管线与帧缓存
    Composition/             Core Image 合成与渲染
    Audio/                   音频提取、预览与离线混音
    Export/                  GIF / HEVC-alpha / H.264 / Live Photo 导出
    Templates/               贴纸、装饰与模板渲染
    FaceTracking/            贴纸面部跟踪
    Storage/                 作品持久化与素材文件存储
LivingFrame/                 SwiftUI 页面与服务层
  Localization/             19 个本地化目录
LivingFrameUITests/          UI 审计和回归测试
```

## 构建与测试

```bash
# Core 包构建
cd Packages/LivingFrameCore
swift build

# Core 包测试（如果当前改动涉及 Core）
swift test

# iOS 模拟器构建
cd ../..
xcodebuild -project LivingFrame.xcodeproj \
  -scheme LivingFrame \
  -destination 'generic/platform=iOS Simulator' \
  -CODE_SIGNING_ALLOWED=NO build
```

要求：Xcode 26+，iOS 18+ 部署目标。

## 真机注意事项

- 代码签名：在 Xcode 中选择自己的 Team，并确认 Bundle ID 与签名配置
- HEVC-alpha 导出：模拟器不支持，透明视频导出必须在真机验证
- Photos/iCloud 媒体：系统权限、原始媒体下载和本地临时文件生命周期可能影响首次导入耗时
- 真实商店截图：应使用代表性的演示项目，不要把空状态或测试占位内容作为 App Store 截图

## App Store 与 ASO

Fastlane 目录包含本地化 metadata、截图和版本化 App Store Connect 快照：

- `fastlane/metadata/<version>/<locale>/`：名称、副标题、关键词、描述、宣传文本和版本更新说明
- `fastlane/screenshots/<version>/<locale>/`：商店截图
- `fastlane/data/<version>/`：价格、可用地区、订阅和 App Store Connect 基线快照
- `fastlane/APP_STORE_REVIEW.md`：当前发布阻塞项与待确认事项

`fastlane/metadata/1.07/` 与 `fastlane/screenshots/1.07/` 是当前本地候选。当前仓库尚无 `fastlane/data/1.07/`；该目录用于记录 App Store Connect 状态，不影响本地构建和候选素材准备，需在确认线上 1.07 记录后再生成。

当前 ASO 工作重点是验证真实关键词搜索排名，而不是只检查字段长度。未上架前不能产生真实的 App Store 自然排名；可以先用竞品和关键词工具建立基线，上架后再用同一 storefront、locale、关键词集合和时间窗口追踪排名变化。

## 隐私边界

应用不要求账号，核心媒体处理在设备端完成。隐私声明、App Privacy 答案、年龄分级、内容权利和 App Review 联系信息仍需在提交前由负责人确认，详见 `fastlane/APP_STORE_REVIEW.md`。
