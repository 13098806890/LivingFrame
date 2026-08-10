import LivingFrameCore
import SwiftUI
import WidgetKit

@main
struct LivingFrameWidgetBundle: WidgetBundle {
    var body: some Widget {
        LivingFrameWidget()
    }
}

struct LivingFrameWidget: Widget {
    let kind = "LivingFrameWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PosterProvider()) { entry in
            PosterEntryView(entry: entry)
        }
        .configurationDisplayName("活影")
        .description("展示你的动态照片静态帧")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry

struct PosterEntry: TimelineEntry {
    let date: Date
    let image: CGImage?
    let title: String?
}

struct PosterProvider: TimelineProvider {
    func placeholder(in context: Context) -> PosterEntry {
        PosterEntry(date: .now, image: nil, title: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PosterEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PosterEntry>) -> Void) {
        completion(Timeline(entries: [makeEntry()], policy: .never))
    }

    private func makeEntry() -> PosterEntry {
        PosterEntry(
            date: .now,
            image: FrameStore.loadPoster(),
            title: FrameStore.loadTitle()
        )
    }
}

// MARK: - View

struct PosterEntryView: View {
    var entry: PosterEntry

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10)
            if let image = entry.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
            VStack {
                Spacer()
                HStack {
                    if let title = entry.title, entry.image != nil {
                        Text(title)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Color(red: 0.91, green: 0.75, blue: 0.36))
                }
                .padding(8)
            }
        }
        .containerBackground(for: .widget) {
            Color(red: 0.04, green: 0.05, blue: 0.10)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28))
                .foregroundStyle(Color(red: 0.91, green: 0.75, blue: 0.36))
            Text("活影")
                .font(.headline)
                .foregroundStyle(.white)
            Text("打开 App 制作你的动态照片")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
    }
}
