# GIFBloom 1.06 ASO 优化报告

> 本文记录 1.06 的历史候选审查。当前本地发布目标已更新为 1.07 / Build 17；版本与快照状态见 [1.07 对比记录](aso-1.07-asc-1.06-comparison.md) 和 `fastlane/APP_STORE_REVIEW.md`。

**审查日期：** 2026-10-23<br>
**目标项目：** LivingFrame（面向用户的品牌名：GIFBloom）<br>
**范围：** iOS App Store；以即将发布的 1.06 为目标，审查当前本地多语言文案候选和截图素材，并用无需 API key 的 ASO 基础方法优化。

## 摘要

GIFBloom 的强项是“从视频或 Live Photo 抠出人物，再在时间轴上合成动态作品，并导出 GIF、透明视频或 Live Photo”。这比泛泛的 GIF 编辑更具体，也能支撑跨市场的商店定位。当前 1.06 本地候选已把原先 17 个市场统一使用的品牌名扩展为本地化“品牌 + GIF 制作”标题，方向正确；标题、副标题及关键词字段均在 Apple 字段限制内。本轮还收紧了美国区关键词，把宽泛的 `motion`、`emoji` 等词替换为更贴近实际功能的词组。

当前最值得先处理的是截图本地化和发布基线核对。仓库的截图说明记录 1.03 截图集仍在使用：英语画面被复制到除简体和繁体中文外的市场；实际检查的日文首图也显示全英文标题和界面。README 与用户指定的 1.05 App Store 基线一致，但旧版 `fastlane/APP_STORE_REVIEW.md` 错把 1.0 历史快照写成当前版本；本轮已修正本地发布记录。App Store Connect 实时版本和构建未在本次读取，上传前仍需只读核对。

本报告使用免费的 `aso-fundamentals` 方法和 Apple 公开资料。没有连接 ASOScan/ASO Maniac 数据服务，因此不提供虚构的搜索量、难度、排名、机会分数或竞品关键词缺口。现阶段结论是**相关性、字段质量与转化素材审查**，不是排名预测。

## 当前基线

| 项目 | 仓库证据 | ASO 影响 |
|---|---|---|
| 产品定位 | 从视频与 Live Photo 提取人物、分层合成，添加背景/贴纸/文字，导出 GIF、透明 HEVC、H.264 或 Live Photo | 以“GIF 制作 + 动态人物抠图/合成”为主线；透明视频、Live Photo 是有辨识度的次级卖点 |
| 本地版本 | Xcode/README 当前为 1.05（Build 10）；本地已有 1.06 的 name/subtitle/keywords 候选 | 1.06 是未提交工作区中的候选，不等同 ASC 已保存或线上已生效 |
| ASC 版本记录 | README 说草稿为 1.05；`fastlane/APP_STORE_REVIEW.md` 仍说首版 1.0 草稿 | 发布前只读确认 ASC 实际版本状态及 build 对齐，并修正文档基线 |
| 商店语言 | 1.05 元数据有 17 个 App Store locale；应用界面有 19 种语言 | 先完善现有 17 个商店页面；`af`、`sw` 界面语言目前没有对应商店 metadata |
| 截图 | 1.03 每市场 5 张；中文外市场复用英文源图。1.06 已本地制作每市场 6 张，共 102 张 | 1.06 现有真实本地化 app UI 和本地化标题；上传前需完成市场语言与视觉审阅 |
| 上架状态 | 发布审查文档记录曾缺少 build、截图和若干审核信息；与 README 的后续状态不一致 | 不能从本地文件确认当前 ASC 状态；不应把草稿候选称为已发布优化 |

## 1.05 App Store 基线 → 1.06 本地候选

按用户指定，以 `fastlane/metadata/1.05/<locale>/` 作为 App Store 版本基线，`fastlane/metadata/1.06/<locale>/` 作为即将发布的目标候选。1.05 的 17 个市场名称均为 `GIFBloom`；1.06 为每个市场加上当地语言的 GIF 制作品类表达。下表逐市场列出副标题、关键词的完整旧值和目标值，以及调整理由。关键词仍是免费方法下的语义选择，没有搜索量或难度验证。

| 市场 | 名称：1.05 → 1.06 | 副标题：1.05 → 1.06 | 关键词：1.05 → 1.06 | 调整理由 |
|---|---|---|---|---|
| 沙特阿拉伯 `ar-SA` | `GIFBloom` → `GIFBloom: صانع GIF` | `ملصقات GIF لواتساب` → `إزالة الخلفية وLive Photo` | `صانع فيديو,صورة متحركة,Live Photo,فيديو شفاف,قصاصات` → `صورة متحركة,فيديو شفاف,ملصقات,مونتاج,قصاصات` | 去掉 WhatsApp 商标；名称补 GIF 制作意图；副标题明确背景移除与 Live Photo；关键词不再重复 Live Photo，保留动态、透明视频、贴纸与剪裁相关词。 |
| 德国 `de-DE` | `GIFBloom` → `GIFBloom: GIFs erstellen` | `GIFs für WhatsApp erstellen` → `Freistellen & Live Photos` | `Live Photo,Fotoanimation,Video Editor,transparente Videos,Collage,animierte Fotos,Sticker` → `Fotoanimation,transparentes Video,Sticker,Collage,Hintergrund entfernen,Porträt,Loop` | 标题新增 GIF 制作品类；副标题改为抠图与 Live Photos；移除 WhatsApp 和重复的 Live Photo，增加背景移除、肖像、循环等实际编辑意图。 |
| 美国 `en-US` | `GIFBloom` → `GIFBloom: GIF Maker` | `Cutouts & WhatsApp GIFs` → `Cutouts & Live Photos` | `Live Photo,photo animation,transparent video,background remover,animated photo,collage` → `background remover,transparent video,sticker maker,video editor,photo collage,animated photo` | 标题补主要品类词；副标题不再借 WhatsApp 品牌定位；关键词删除副标题已有的 Live Photo，去掉重复/泛化覆盖，补贴纸制作、视频编辑和拼贴意图。 |
| 西班牙 `es-ES` | `GIFBloom` → `GIFBloom: Creador de GIF` | `GIFs y stickers de WhatsApp` → `Recortes y Live Photos` | `crear stickers,video animado,foto animada,Live Photo,recorte personas,fondo transparente,collage` → `video animado,foto animada,stickers,quitar fondo,collage,marcos,retratos,edición de vídeo` | 标题说明 GIF 创作；副标题转为剪裁与 Live Photos，去掉第三方品牌；关键词删除重复的 Live Photo/recorte 和泛词，改为动画、去背景、相框与视频编辑意图。 |
| 法国 `fr-FR` | `GIFBloom` → `GIFBloom : Créateur de GIF` | `GIF et stickers WhatsApp` → `Détourage et Live Photos` | `créateur vidéo,photo animée,Live Photo,arrière-plan transparent,recadrage personnes,collage` → `photo animée,vidéo transparente,stickers,collage,personnes,retouche,portrait,boucle,cadres` | 标题明确 GIF 创作；副标题突出抠图与 Live Photos；移除 WhatsApp、重复 Live Photo，关键词扩展透明视频、拼贴、肖像及循环编辑方向。 |
| 印度 `hi` | `GIFBloom` → `GIFBloom: GIF बनाएं` | `WhatsApp GIF स्टिकर बनाएं` → `कटआउट और Live Photo` | `वीडियो,कटआउट,पारदर्शी,Live Photo` → `वीडियो,स्टिकर,पारदर्शी,फोटो,कोलाज` | 标题补 GIF 制作品类；副标题转向抠图与 Live Photo；清除 WhatsApp 并把重复的 cutout/Live Photo 换成贴纸、透明、照片与拼贴覆盖。 |
| 印尼 `id` | `GIFBloom` → `GIFBloom: Pembuat GIF` | `GIF & Stiker WhatsApp` → `Hapus Latar & Live Photo` | `pembuat video,foto animasi,Live Photo,video transparan,edit foto,kolase,stiker bergerak` → `video transparan,animasi,kolase,stiker bergerak,potret,edit foto,editor video` | 标题新增 GIF 制作含义；副标题直说去背景与 Live Photo；不再重复 Live Photo，补肖像和视频编辑，保留动态贴纸/照片编辑相关覆盖。 |
| 意大利 `it` | `GIFBloom` → `GIFBloom: Crea GIF` | `GIF e sticker per WhatsApp` → `Scontorno e Live Photo` | `foto animate,Live Photo,editor video,video trasparente,ritaglio persone,collage,animazioni` → `foto animate,video trasparente,sticker,collage,montaggio,ritratti,rimuovi sfondo,loop,cornici` | 标题增加 GIF 创作词；副标题用抠图与 Live Photo 代替 WhatsApp 宣传；移除重复的 Live Photo，新增去背景、肖像、循环及相框等功能词。 |
| 日本 `ja` | `GIFBloom` → `GIFBloom：GIFメーカー` | `LINE用GIFスタンプを作成` → `人物切り抜き・Live Photo` | `動く写真,Live Photo,動画編集,透明動画,背景透過,コラージュ,写真アニメ` → `動く写真,透明動画,背景透過,コラージュ,スタンプ,ループ,動画編集` | 标题新增本地化 GIF maker 词；副标题说明人物剪裁与 Live Photo，去掉 LINE 商标；关键词去除重复 Live Photo，保留视频编辑并加入贴纸、循环。 |
| 韩国 `ko` | `GIFBloom` → `GIFBloom: GIF 만들기` | `카카오톡 GIF 이모티콘 제작` → `인물 누끼·Live Photo` | `움직이는 사진,Live Photo,영상 편집,투명 영상,배경 제거,콜라주` → `움직이는 사진,투명 영상,배경 제거,스티커,콜라주,프레임,애니메이션` | 标题增加 GIF 制作意图；副标题说明人物抠图与 Live Photo，移除 KakaoTalk；关键词去掉重复 Live Photo，扩展贴纸、拼贴、动画编辑方向。 |
| 巴西葡萄牙语 `pt-BR` | `GIFBloom` → `GIFBloom: Criador de GIF` | `GIFs e figurinhas do WhatsApp` → `Recortes e Live Photos` | `foto animada,Live Photo,editor de vídeo,vídeo transparente,recorte de pessoas,colagem,animação` → `foto animada,vídeo transparente,figurinhas,colagem,remover fundo,molduras,retrato,efeitos` | 标题补 GIF 创作品类；副标题从 WhatsApp 贴纸改为剪裁与 Live Photos；关键词不重复 Live Photo/剪裁，增加去背景、贴纸、相框和肖像。 |
| 俄罗斯 `ru` | `GIFBloom` → `GIFBloom: Создание GIF` | `GIF-стикеры для Telegram` → `Вырезка и Live Photo` | `анимация фото,Live Photo,прозрачное видео,вырезка людей` → `анимация фото,прозрачное видео,стикеры,коллаж,рамки` | 标题增加 GIF 创作词；副标题突出剪裁与 Live Photo 并移除 Telegram 商标；关键词移除重复 Live Photo/剪裁，补贴纸、拼贴和相框。 |
| 泰国 `th` | `GIFBloom` → `GIFBloom: สร้าง GIF` | `GIF สติกเกอร์สำหรับ LINE` → `ลบพื้นหลังและ Live Photo` | `ภาพเคลื่อนไหว,ตัดพื้นหลัง,โปร่งใส` → `ภาพเคลื่อนไหว,โปร่งใส,สติกเกอร์` | 标题本地化表达 GIF 制作；副标题说明去背景与 Live Photo，移除 LINE；关键词去除与副标题重复的去背景，保留动态/透明并增加贴纸。 |
| 土耳其 `tr` | `GIFBloom` → `GIFBloom: GIF Oluştur` | `WhatsApp GIF ve çıkartmalar` → `Arka plan silme & Live Photo` | `animasyonlu fotoğraf,Live Photo,video düzenleme,şeffaf video,arka plan kaldırma,kolaj` → `animasyonlu fotoğraf,şeffaf video,çıkartma,kolaj,portre,filtre,döngü,kesit,çerçeve` | 标题增加 GIF 创作品类；副标题说明去背景与 Live Photo，去掉 WhatsApp；关键词删除重复 Live Photo/背景移除，新增贴纸、肖像、循环和相框。 |
| 越南 `vi` | `GIFBloom` → `GIFBloom: Tạo ảnh GIF` | `Tạo GIF sticker cho Zalo` → `Tách nền & Live Photo` | `ảnh động,Live Photo,chỉnh sửa video,video trong suốt,tách nền,ghép ảnh,hoạt ảnh` → `video trong suốt,nhãn dán,ghép ảnh,hoạt hình,khung hình,ảnh động,cắt ghép video` | 标题说明 GIF 制作；副标题强调去背景与 Live Photo，去掉 Zalo；关键词移除重复 Live Photo/背景抠图，强化贴纸、动态照片、拼贴与视频剪辑。 |
| 简体中文 `zh-Hans` | `GIFBloom` → `GIFBloom：GIF制作` | `抠图，GIF制作，微信表情包` → `人物抠图与 Live Photo` | `动态贴纸,透明视频,视频转动图,动态照片,人物分割,剪影,照片动画,拼贴` → `动态贴纸,透明视频,视频转动图,动态照片,表情包,剪影,去背景,拼贴` | 标题保留 GIF 品类词；副标题用人物抠图和 Live Photo 讲清差异，移除微信品牌；关键词移除与副标题近义的“人物分割”，保留动画/透明视频/贴纸/拼贴覆盖。 |
| 繁体中文 `zh-Hant` | `GIFBloom` → `GIFBloom：GIF 製作` | `摳圖、GIF製作、LINE貼圖` → `人物去背與 Live Photo` | `人物去背,動態照片,GIF製作,透明影片,影片編輯,拼貼,貼圖` → `影片編輯,動態照片,透明影片,剪輯,拼貼,貼圖,動畫,動圖,畫框,濾鏡` | 标题增加 GIF 制作品类；副标题明确人物去背与 Live Photo，移除 LINE；关键词去除名称/副标题重复词，保留影片编辑并扩展动画、动图、画框、滤镜。 |

**各市场共同理由：**1.05 名称只有品牌，没有描述品类；1.06 在名称中补入当地 GIF 制作词，以改善搜索相关性和首眼理解。副标题从未经授权/与功能关系不稳定的第三方社交应用名称，改为实际功能。关键词从名称、副标题和品牌相关重复词中释放空间，再覆盖动画照片、透明视频、去背景、贴纸、拼贴和编辑等实际能力。以上属于语义相关性优化；由于没有关键词量级数据，不能断言某个词的热度或排名会提高。

## 1.06 文案候选审查

已逐个读取 17 个 locale 的本地候选。名称均不超过 30 字符，副标题不超过 30 字符，关键词字段均不超过 Apple 当前 ASC 参考中的 100 字节上限。关键词字节占用约为 **81–96B**；不必为凑满字段而添加低相关词。名称和副标题有明确品类/收益表达，关键词基本避开名称和副标题里的主词。

| 市场 | 1.06 名称 | 1.06 副标题 | 观察 |
|---|---|---|---|
| 美国 | `GIFBloom: GIF Maker` | `Cutouts & Live Photos` | 名称直说 GIF 制作；副标题突出人物抠图和 Live Photo。关键词已调整为 `background remover,transparent video,sticker maker,video editor,photo collage,animated photo`，去掉较宽泛或产品主线较弱的 `motion`、`emoji`、`frame`、`loop` |
| 简体中文 | `GIFBloom：GIF制作` | `人物抠图与 Live Photo` | 形成“品类词 + 差异能力”的组合；关键词覆盖动态贴纸、透明视频、视频转动图、表情包等相关意图 |
| 日本 | `GIFBloom：GIFメーカー` | `人物切り抜き・Live Photo` | 主要能力清楚；需用日语截图与母语校对支持转化 |
| 德国 | `GIFBloom: GIFs erstellen` | `Freistellen & Live Photos` | 名称更有搜索含义；建议母语者确认 `Freistellen` 在视频人物抠图语境的自然度 |
| 巴西葡萄牙 | `GIFBloom: Criador de GIF` | `Recortes e Live Photos` | 定位简洁；需确保“recortes”对目标用户清楚表达人物抠图 |

相比 1.05，1.06 候选已清理 WhatsApp、LINE、KakaoTalk、Telegram、Zalo 等其他应用名称，降低商标/审核风险。Apple 明确要求关键词相关且不得包含竞争应用名称或未经授权的商标用法；这类平台名不应作为搜索词使用。分享兼容性可以在描述中以合规、事实准确的方式说明，不要把第三方品牌塞进标题、副标题或关键词字段。

1.06 本地候选已覆盖全部 17 个 App Store 市场。上述完整基线比较列出每个市场从 1.05 到 1.06 的名称、副标题、关键词和理由；本次根据审查补强了阿拉伯语、西班牙语、意大利语、日语、越南语、繁体中文字段，并优化美国区关键词。候选尚未上传 ASC，不能称为已经生效。

### 字段放置原则

- 名称承载品牌和一个最明确的品类词（如各 locale 候选里的 GIF maker 表达）。
- 副标题承载主要收益/差异：人物抠图、Live Photo、透明视频创作，不重复标题里的 GIF 制作意图。
- 关键词字段放入标题/副标题没有覆盖的具体功能词；逗号分隔、逗号后不加空格，删掉重复词、泛词和低相关词。
- 长描述服务用户理解与转化，不以堆叠同义词替代关键词字段。把“本地处理、不上传所选素材”这类可信价值放在容易看到的位置，并确保与实际实现一致。
- 任何翻译都应由当地使用者审校。长度合规不代表语义自然或搜索需求已验证。

## 2. 截图与页面转化

旧版 1.03 首图的利益点“Bring photos to life / Turn photos and Live Photos into animated cutouts”直观，但除 zh-Hans/zh-Hant 以外复用了英文图。对日语页面的实际抽查确认，旧图首图标题、说明、应用内控件均为英文。为解决此问题，本轮为 1.06 重新运行本地化 app，制作了 17 个市场各 6 张真实界面截图；标题和 app UI 均按目标语言呈现。

1.06 本地截图按“时间轴编辑 → 贴纸 → 导出选项 → 画布 → 文字 → 裁剪”展示核心功能，使用虚构成年人物演示素材，避免把测试夹具中的儿童素材放入商店图。截图由真实 app UI 与本地化功能标题组合；各市场仍应由母语者检查用词、RTL 排版和缩略图可读性。

## 3. 优先级清单

| 优先级 | 工作项 | 建议动作 | 完成依据 |
|---|---|---|---|
| P0 | 核对 ASC 发布基线 | 本地版本记录已统一为 1.05 基线 / 1.06 候选；上传前只读确认 ASC 版本号、状态、对应 build、截图与元数据 | 本地文档统一；ASC 实时状态有核对日期与证据，1.06 候选未误报为线上值 |
| P1 | 本地化截图 | 本地截图集已覆盖 17 个市场，每市场 6 张；发布前复核母语表达、RTL 和缩略图可读性 | 102 张本地 PNG 已生成；审阅通过后再上传 |
| P1 | 定稿 1.06 元数据 | 保留品牌 + GIF 制作标题方向；由母语者复核 17 组名称、副标题与关键词 | 字段限制合格；无品牌名滥用、明显直译、字段重复或过度宽泛词 |
| P1 | 定义可测关键词集合 | 每个重点市场先选 5–10 个紧贴功能的候选词；上架后用相同 storefront、语言和周期记录曝光、产品页访问和下载 | 有可重复的基线；不把商店搜索建议误报成搜索量/排名 |
| P2 | 优化描述首屏 | 首两句先说“从视频/Live Photo 抠出人物并制作动态作品”，随后概括合成、导出与本地处理 | 用户在展开长描述前能理解用途、输入和输出 |
| P2 | 上架后分开测素材 | 条件允许后，用产品页优化实验单独比较截图主题/顺序；一次只改变一个主要变量 | 有足够展示和转化样本后再选胜出版本；低样本时结论标记不确定 |

## 4. 测量方案与数据边界

本地工作区没有 App Store Connect 分析数据，也没有按市场保存的关键词排名或下载转化基线；因此本报告不能判断当前排名或估算流量。1.06 上架后，应从 ASC 为每个目标市场留存搜索展示、产品页浏览和下载/转化基线。Apple 搜索相关性会看名称、副标题、关键词和主类别，用户行为还包含下载、评分与评论；搜索与转化表现不能仅凭文案长度推断。

上架后按每个重点市场记录同一组指标：搜索展示/曝光、产品页浏览、下载或转化，以及可用时的关键词自然排名。先观察至少一个完整的 2–4 周窗口，再对标题/副标题/关键词版本做单变量比较。截图实验应独立进行，不要同时改 metadata 与素材后把结果归因给单一改动。没有足够样本时不判定胜负。

本次没有访问 App Store Connect 的实时分析，也没有使用需要 API key/credits 的 ASOScan 或 ASO Maniac 数据功能。因此：

- 不报告关键词搜索量、难度、自然排名、安装量或竞品关键词缺口。
- Apple 搜索建议可用于发现词语线索，但不能当作词量或排名数据。
- 不承诺某个词能带来流量或下载；本地没有可用于判断的当前市场分析数据。

## 依据

- 仓库：`README.md`、`fastlane/APP_STORE_REVIEW.md`、`fastlane/metadata/1.05/`、`fastlane/metadata/1.06/`、`fastlane/screenshots/README.md`、`fastlane/screenshots/1.03/`。
- 免费方法：ASOScan `aso-fundamentals`（无需 API key），以及 [ASOScan/aso-skills](https://github.com/ASOScan/aso-skills) 的公开说明。关键词数据、排名和分数属于数据技能范围，本次未调用。
- Apple：[App Store Search](https://developer.apple.com/app-store/search/)；[Creating Your Product Page](https://developer.apple.com/app-store/product-page/)；[App Information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)；[Platform Version Information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)；[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。

**结论：**保留 1.06 的本地化“品牌 + GIF 制作”标题方向。本轮已纠正本地版本文档，并为 17 个市场补齐本地化截图；上传前仍需审阅截图并只读核对 ASC 实时记录。当前报告是免费方法下的定性 ASO 审查，具体词效和排序表现需根据上架后的真实市场数据验证。

## 本轮问题处理记录（2026-10-26）

- **版本记录冲突已在本地文档中纠正：**`fastlane/APP_STORE_REVIEW.md` 现在以用户指定的 1.05 App Store 版本作为本次比较基线，1.06 标为本地候选，并把 `fastlane/data/1.0/` 明确标记为 2026-09-17 的历史产品/价格快照，不再称 1.0 为当前版本。README 中的 1.05 记录与此一致。
- **本地化截图已补齐：**1.06 为 17 个市场各准备 6 张本地化 iPhone 截图，共 102 张。通过独立 iOS 模拟器运行本地化 app 采集真实界面，以虚构成年人物演示素材构建项目；随后添加各市场本地化功能标题。原有 1.03 平面图仍保留为历史版本素材，未被假标为本地化。`fastlane/screenshots/README.md` 和发布检查清单已同步。
- **ASC 线上状态仍待只读确认：**本地工作没有调用 ASC，也没有上传或提交。上线前仍须核对线上版本、build、截图和元数据状态。

1.06 本地截图已生成，待逐市场检查文案、画面和 RTL 排版后再决定上传。当前没有执行 App Store Connect 上传或提交。
