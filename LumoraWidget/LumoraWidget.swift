import WidgetKit
import SwiftUI
import UIKit

struct PicksEntry: TimelineEntry {
    let date: Date
    let images: [UIImage]
    let picks: Int
    let total: Int
}

struct PicksProvider: TimelineProvider {
    static let group = "group.com.balasinoss.lumora"

    func load() -> PicksEntry {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PicksProvider.group),
              let d = try? Data(contentsOf: dir.appendingPathComponent("widget.json")),
              let info = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return PicksEntry(date: Date(), images: [], picks: 0, total: 0)
        }
        let names = info["images"] as? [String] ?? []
        let imgs = names.compactMap { UIImage(contentsOfFile: dir.appendingPathComponent($0).path) }
        return PicksEntry(date: Date(), images: imgs, picks: info["picks"] as? Int ?? 0, total: info["total"] as? Int ?? 0)
    }

    func placeholder(in context: Context) -> PicksEntry { PicksEntry(date: Date(), images: [], picks: 0, total: 0) }
    func getSnapshot(in context: Context, completion: @escaping (PicksEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PicksEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct PicksWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: PicksEntry
    let accent = Color(red: 1.0, green: 0.56, blue: 0.30)

    var body: some View {
        if entry.images.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "camera.aperture").font(.system(size: 30)).foregroundStyle(accent)
                Text("Lumora").font(.headline)
                Text("Your picks appear here").font(.caption2).foregroundStyle(.secondary)
            }
        } else if family == .systemSmall {
            Image(uiImage: entry.images[0]).resizable().scaledToFill()
                .overlay(alignment: .bottomLeading) { label.padding(8) }
        } else {
            HStack(spacing: 3) {
                ForEach(0..<min(entry.images.count, family == .systemMedium ? 3 : 4), id: \.self) { i in
                    Image(uiImage: entry.images[i]).resizable().scaledToFill().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
            }
            .overlay(alignment: .bottomLeading) { label.padding(8) }
        }
    }

    var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill").foregroundStyle(accent)
            Text("\(entry.picks) picks").font(.caption.bold())
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

@main
struct LumoraWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LumoraPicks", provider: PicksProvider()) { entry in
            PicksWidgetView(entry: entry).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Lumora Picks")
        .description("Your latest picked photos.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
