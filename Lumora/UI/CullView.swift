import SwiftUI

/// Full-screen review: swipe up = pick, swipe down = reject, left/right = next/previous.
struct CullView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var smart: SmartSort
    @Environment(\.dismiss) var dismiss
    let ids: [UUID]
    @State private var index = 0
    @State private var offset: CGSize = .zero
    @State private var big: UIImage?
    @State private var feedback: String?

    var current: PhotoItem? {
        guard index < ids.count else { return nil }
        return library.items.first { $0.id == ids[index] }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let it = current {
                VStack(spacing: 0) {
                    header(it)
                    GeometryReader { geo in
                        ZStack {
                            if let img = big ?? library.thumbnail(it) {
                                Image(uiImage: img).resizable().scaledToFit()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .offset(offset)
                                    .rotationEffect(.degrees(Double(offset.width / 30)))
                                    .opacity(1 - Double(abs(offset.height)) / 600)
                            }
                            if let f = feedback {
                                Text(f).font(.system(size: 28, weight: .heavy)).padding(18)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture()
                            .onChanged { offset = $0.translation }
                            .onEnded { g in
                                let t = g.translation
                                if t.height < -110 { decide(it, pick: true) }
                                else if t.height > 110 { decide(it, pick: false) }
                                else if t.width < -80 { move(1) }
                                else if t.width > 80 { move(-1) }
                                withAnimation(.spring(duration: 0.25)) { offset = .zero }
                            })
                    }
                    footer(it)
                }
                .task(id: it.id) { await loadBig(it) }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Theme.gradient)
                    Text("All reviewed").font(.title2.bold())
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
        }
        .foregroundStyle(.white)
    }

    func header(_ it: PhotoItem) -> some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 36, height: 36).background(Theme.panel2, in: Circle()) }
            Spacer()
            VStack(spacing: 2) {
                Text("\(index + 1) of \(ids.count)").font(.system(size: 14, weight: .bold))
                if let a = it.analysis {
                    Text("Sharpness \(Int(a.sharpness))" + (a.faceQuality.map { " · Face \(Int($0 * 100))" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(Theme.text2)
                }
            }
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    func footer(_ it: PhotoItem) -> some View {
        VStack(spacing: 12) {
            let albums = smart.albums(for: it).compactMap { id -> String? in
                if id.hasPrefix("jersey-") { return "#" + String(id.dropFirst(7)) }
                return smart.categories.first { $0.id == id }?.name
            }
            if !albums.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(albums, id: \.self) { Text($0).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(Theme.panel2, in: Capsule()) } }
                        .padding(.horizontal)
                }
            }
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { r in
                    Image(systemName: r <= it.rating ? "star.fill" : "star").foregroundStyle(r <= it.rating ? Theme.accent : Theme.text2)
                        .onTapGesture { var x = it; x.rating = x.rating == r ? 0 : r; library.update(x, backup: false) }
                }
            }
            HStack(spacing: 28) {
                circle("xmark", it.isRejected ? .red : Theme.panel2) { decide(it, pick: false) }
                circle("arrow.uturn.backward", Theme.panel2) { library.setPick(it, picked: nil); move(0) }
                circle("flag.fill", it.flagged ? Theme.accent : Theme.panel2) { decide(it, pick: true) }
            }
            Text("Swipe up to pick · down to reject · sideways to browse").font(.system(size: 11)).foregroundStyle(Theme.text2)
        }
        .padding(.bottom, 14)
    }

    func circle(_ icon: String, _ bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold)).frame(width: 56, height: 56).background(bg, in: Circle())
        }
    }

    func decide(_ it: PhotoItem, pick: Bool) {
        library.setPick(it, picked: pick)
        UIImpactFeedbackGenerator(style: pick ? .medium : .rigid).impactOccurred()
        withAnimation { feedback = pick ? "Picked" : "Rejected" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { feedback = nil }; move(1) }
    }

    func move(_ d: Int) {
        big = nil
        index = min(max(index + d, 0), ids.count)
    }

    func loadBig(_ it: PhotoItem) async {
        let url = library.originalURL(it)
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = PhotoSource(url: url), let cg = src.quickImage(maxPixel: 2048) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if current?.id == it.id { big = img }
    }
}

/// Bursts: groups of frames shot within a second; keep the best in one tap.
struct BurstsView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State private var gap: Double = 1.0

    var body: some View {
        let bursts = library.bursts(gap: gap)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading) {
                        Text("Frames closer than \(String(format: "%.1f", gap)) s count as one burst").font(.footnote).foregroundStyle(Theme.text2)
                        Slider(value: $gap, in: 0.3...3, step: 0.1).tint(Theme.accent)
                    }.padding(.horizontal)
                    if bursts.isEmpty {
                        Text("No bursts found. Bursts need the capture time stored in the photo (EXIF).")
                            .foregroundStyle(Theme.text2).padding()
                    }
                    ForEach(Array(bursts.enumerated()), id: \.offset) { _, b in
                        let best = library.bestOf(b)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(b.count) frames").font(.system(size: 14, weight: .bold))
                                if let d = b.first?.captured { Text(d.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(Theme.text2) }
                                Spacer()
                                Button("Keep best") { library.keepBest([b]) }.font(.system(size: 13, weight: .semibold)).tint(Theme.accent)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(b) { it in
                                        Thumb(item: it, showScore: true)
                                            .frame(width: 110, height: 110)
                                            .opacity(it.isRejected ? 0.35 : 1)
                                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(it.id == best?.id ? Theme.accent : .clear, lineWidth: 3))
                                            .overlay(alignment: .topLeading) {
                                                if it.id == best?.id { Image(systemName: "crown.fill").font(.system(size: 12)).foregroundStyle(Theme.accent).padding(5) }
                                            }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(Theme.bg)
            .navigationTitle("Bursts").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Keep best in all") { library.keepBest(bursts) }.disabled(bursts.isEmpty)
                }
            }
        }
    }
}

/// Builds a shareable web gallery (folder with index.html + JPEGs).
enum GalleryBuilder {
    static func build(name: String, items: [PhotoItem], progress: @escaping (Int) -> Void) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var root: URL
        var scoped: URL?
        if let folder = CloudSync.shared.resolveFolder(), folder.startAccessingSecurityScopedResource() {
            scoped = folder
            root = folder.appendingPathComponent("Galleries/\(safe)", isDirectory: true)
        } else {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(safe, isDirectory: true)
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var names: [String] = []
        for (i, it) in items.enumerated() {
            let s = LibraryStore.shared.settings(for: it)
            guard let src = PhotoSource(url: LibraryStore.shared.originalURL(it)),
                  let img = RenderPipeline.shared.renderFull(source: src, settings: s, maxDimension: 2400),
                  let data = RenderPipeline.shared.encode(img, format: .jpeg, quality: 0.9, maxLongEdge: 2400, properties: [:]) else { continue }
            let file = String(format: "%03d.jpg", i + 1)
            try? data.write(to: root.appendingPathComponent(file), options: .atomic)
            names.append(file)
            DispatchQueue.main.async { progress(i + 1) }
        }
        let tiles = names.map { "<a href=\"\($0)\"><img loading=\"lazy\" src=\"\($0)\"></a>" }.joined(separator: "\n")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(safe)</title><style>
        body{margin:0;background:#0b0b0d;color:#fff;font-family:-apple-system,Helvetica,sans-serif}
        h1{font-size:22px;padding:20px 16px 4px;margin:0}p{color:#999;margin:0 16px 14px}
        .g{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:4px;padding:4px}
        .g img{width:100%;height:100%;object-fit:cover;aspect-ratio:3/2;display:block}
        </style></head><body><h1>\(safe)</h1><p>\(names.count) photos · tap to open full size</p><div class="g">
        \(tiles)
        </div></body></html>
        """
        try? html.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return root
    }
}
