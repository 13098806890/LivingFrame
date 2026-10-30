# GIFBloom 1.07 ASO 候选与 ASC 1.06 对比

**核对日期：**2026-10-27<br>
**范围：**本地 Fastlane 1.07 候选，对照 App Store Connect 已发布的 1.06。仅只读查看 ASC；没有上传或修改商店内容。

## 已整理到 1.07

- 将本地优化过的 `fastlane/metadata/1.06/` 和 `fastlane/screenshots/1.06/` 原样复制到 1.07；保留原 1.06 文件夹作为本地留档。
- Fastlane 默认商店版本从 1.06 切换到 1.07。
- 候选覆盖 17 个 App Store locale。截图候选共 102 张，每个 locale 6 张。

## ASC 英文（美国）页面核对结果

| 字段 | ASC 1.06 | 本地 1.07 候选 | 结果 |
|---|---|---|---|
| 版本 / build | 1.06 / build 15 | 本地商店素材目标为 1.07；代码 build 17 | 版本线不同，符合本次目标 |
| 关键词 | `background remover,transparent video,sticker,animation,collage,loop,portrait,frame,motion,emoji` | `background remover,transparent video,sticker maker,video editor,photo collage,animated photo` | 不同；候选替换成更明确的贴纸制作、视频编辑、拼贴和动态照片意图 |
| 截图 | 页面显示 5 张，文件名为 `Screenshot 01-bring-photos-to-life.png` 等 | 6 张：编辑器、贴纸、导出、画布、文字、裁剪；各市场本地化 | 不同；候选增加一张，并改为每市场本地化的功能顺序和素材 |
| 描述 | ASC 英文长描述 | 本地英文长描述 | 一致 |
| 推广文本 | `Process one item at a time...` | 本地英文推广文本 | 一致 |
| What's New | 6 条功能更新 | 本地 `release_notes.txt` | 一致 |
| Support / Marketing URL | ASC 页面显示的两个链接 | 本地对应 URL 文件 | 一致 |

## 本地候选包含的 ASO 调整

本地 1.07 候选沿用了之前整理的 17 市场优化：

1. 标题从单独品牌名改为品牌名加当地语言的 GIF 制作品类表达。
2. 副标题移除 WhatsApp、LINE、KakaoTalk、Telegram、Zalo 等第三方应用名称，改为人物抠图、去背景、Live Photo 等产品能力。
3. 按各语言调整关键词，减少标题/副标题重复词，覆盖透明视频、贴纸、拼贴、背景移除、动态照片等实际功能。
4. 截图从 ASC 英文页目前显示的 5 张，更新为本地 17 个市场各 6 张的本地化候选。

## 对比边界

ASC 1.06 的逐字段值已在英文（美国）页面核对。ASC 页面提供了 17 个 locale 选项，但本次没有逐一打开其他 16 个市场，因此不能据此断言那些市场的线上字段逐项与 1.07 不同或相同。ASC 当前页面也没有显示各 locale 的名称/副标题字段；上面这两项仅描述本地候选的优化方向，没有作为已核实的线上差异列入字段表。

这些改动是待审阅的本地候选，并未上传到 ASC，也没有排名、搜索量或转化数据证明其效果。上传前仍应审阅 17 个市场的文案和截图，并在 ASC 逐 locale 对照。

## 2026-10-29 本地版本记录

当前 Xcode 目标版本为 1.07 / Build 17，Fastlane 默认商店素材版本也是 1.07。`fastlane/metadata/1.07/` 和 `fastlane/screenshots/1.07/` 已有本地候选；`fastlane/data/1.07/` 尚不存在。该目录用于保存确认后的 App Store Connect 状态与价格快照，不影响本地版本审查，也不代表 1.07 已创建或发布。确认 ASC 上的 1.07 版本记录后再生成快照。
