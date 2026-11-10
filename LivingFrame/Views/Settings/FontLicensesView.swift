import SwiftUI

struct FontLicensesView: View {
    private struct FontInfo: Identifiable {
        let id: String
        let nameKey: String
        let description: String
        let copyright: String
        let sourceURL: String
    }

    @State private var licenseText = ""

    private let fonts = [
        FontInfo(
            id: "ma-shan-zheng",
            nameKey: "马善政体",
            description: "厚重的毛笔字风格，有传统书法气势，适合节庆和国风标题。",
            copyright: "Copyright 2018 The Ma Shan Zheng Project Authors.",
            sourceURL: "https://github.com/googlefonts/mashanzheng"
        ),
        FontInfo(
            id: "zcool-kuaile",
            nameKey: "站酷快乐体",
            description: "活泼圆润、俏皮轻松，适合可爱风格和短标题。",
            copyright: "Copyright 2018 The ZCOOL KuaiLe Project Authors.",
            sourceURL: "https://github.com/googlefonts/zcool-kuaile"
        ),
        FontInfo(
            id: "long-cang",
            nameKey: "龙苍",
            description: "手写书法风格，笔画有自然纹理，适合短句和标题。",
            copyright: "Copyright 2018 The Long Cang Project Authors.",
            sourceURL: "https://github.com/google/fonts/tree/main/ofl/longcang"
        ),
        FontInfo(
            id: "zcool-xiaowei",
            nameKey: "站酷小薇体",
            description: "清秀的衬线字，偏文艺复古，适合生活方式类标题。",
            copyright: "Copyright 2018 The ZCOOL XiaoWei Project Authors.",
            sourceURL: "https://github.com/google/fonts/tree/main/ofl/zcoolxiaowei"
        )
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(NSLocalizedString(
                    "这些字体随 GIFBloom App 一并提供，均采用 SIL Open Font License 1.1。字体文件不可单独出售。",
                    comment: "Bundled font license summary"
                ))
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(fonts) { font in
                    SectionCard(verbatimTitle: NSLocalizedString(font.nameKey, comment: "Bundled font name")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(NSLocalizedString(font.description, comment: "Bundled font style description"))
                                .font(.subheadline)
                                .foregroundStyle(LF.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            Label("SIL Open Font License 1.1", systemImage: "checkmark.seal")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(LF.actionPrimary)

                            Text(font.copyright)
                                .font(.caption2)
                                .foregroundStyle(LF.textSecondary)
                                .textSelection(.enabled)

                            if let sourceURL = URL(string: font.sourceURL) {
                                Link(destination: sourceURL) {
                                    Label("查看官方字体仓库", systemImage: "arrow.up.right.square")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundStyle(LF.actionPrimary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !licenseText.isEmpty {
                    SectionCard(title: "完整字体许可") {
                        DisclosureGroup {
                            Text(licenseText)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(LF.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        } label: {
                            Label("查看 SIL Open Font License 1.1 全文", systemImage: "doc.text")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(LF.textPrimary)
                        }
                        .tint(LF.actionPrimary)
                    }
                }
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
        .lfNavigationTitle("字体版权与许可")
        .navigationBarTitleDisplayMode(.inline)
        .magicBackground()
        .task {
            licenseText = loadLicenseText()
        }
    }

    private func loadLicenseText() -> String {
        let candidates = [
            Bundle.main.url(forResource: "FONTS_LICENSES", withExtension: "txt", subdirectory: "Fonts"),
            Bundle.main.url(forResource: "FONTS_LICENSES", withExtension: "txt", subdirectory: "Resources/Fonts"),
            Bundle.main.url(forResource: "FONTS_LICENSES", withExtension: "txt")
        ]
        for url in candidates.compactMap({ $0 }) {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents
            }
        }
        return NSLocalizedString("许可证文件暂不可用。", comment: "Bundled font license unavailable fallback")
    }
}
