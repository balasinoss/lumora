import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var cloud: CloudSync
    @EnvironmentObject var smart: SmartSort
    @State private var showPicker = false
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var editing: PhotoItem?
    @State private var album = "all"
    @State private var sortBySharpness = false
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var columns = 3

    var gridCols: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 2), count: columns) }

    /// Album id -> photo count (smart albums computed live; one photo can be in many albums)
    var albumCounts: [String: Int] {
        var c: [String: Int] = [:]
        for it in library.items { for a in smart.albums(for: it) { c[a, default: 0] += 1 } }
        return c
    }

    var filtered: [PhotoItem] {
        var list: [PhotoItem]
        switch album {
        case "all": list = library.items
        case "flagged": list = library.items.filter(\.flagged)
        case "rated": list = library.items.filter { $0.rating > 0 }
        case "unsorted": list = library.items.filter { $0.analysis == nil }
        default: list = library.items.filter { smart.albums(for: $0).contains(album) }
        }
        if sortBySharpness { list.sort { ($0.analysis?.sharpness ?? -1) > ($1.analysis?.sharpness ?? -1) } }
        return list
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.bg.ignoresSafeArea()
                if library.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            albumBar
                            LazyVGrid(columns: gridCols, spacing: 2) {
                                ForEach(filtered) { item in
                                    Thumb(item: item, selected: selection.contains(item.id), selecting: selecting, showScore: sortBySharpness)
                                        .onTapGesture {
                                            if selecting {
                                                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                                            } else { editing = item }
                                        }
                                        .contextMenu { menu(for: item) }
                                }
                            }
                            if filtered.isEmpty {
                                Text("No photos in this album yet").foregroundStyle(Theme.text2).padding(.top, 40)
                            }
                            Color.clear.frame(height: 90)
                        }
                    }
                    .gesture(MagnificationGesture().onEnded { v in
                        withAnimation { columns = v > 1 ? max(2, columns - 1) : min(6, columns + 1) }
                    })
                }
                statusPills
            }
            .navigationTitle("Lumora")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: cloud.isConfigured ? (cloud.busy > 0 ? "icloud.and.arrow.up" : "checkmark.icloud") : "gearshape")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selecting {
                        Menu {
                            if let c = library.clipboard, !selection.isEmpty {
                                Button { for it in library.items where selection.contains(it.id) { library.paste(c, onto: it) }; endSelect() } label: {
                                    Label("Paste Settings", systemImage: "doc.on.clipboard") }
                            }
                            Button { for var it in library.items where selection.contains(it.id) { it.flagged = true; library.update(it) }; endSelect() } label: {
                                Label("Flag", systemImage: "flag") }
                            Button { smart.enqueue(library.items.filter { selection.contains($0.id) }, force: true); endSelect() } label: {
                                Label("Re-analyze", systemImage: "sparkles") }
                            Button(role: .destructive) { for it in library.items where selection.contains(it.id) { library.delete(it) }; endSelect() } label: {
                                Label("Delete", systemImage: "trash") }
                        } label: { Text("Actions") }.disabled(selection.isEmpty)
                        Button("Done") { endSelect() }.bold()
                    } else if !library.items.isEmpty {
                        Menu {
                            Toggle(isOn: $sortBySharpness) { Label("Sort by sharpness", systemImage: "scope") }
                            Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                            Button { smart.enqueue(library.items) } label: { Label("Analyze unsorted photos", systemImage: "sparkles") }
                        } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    }
                }
            }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .sheet(isPresented: $showPicker) {
                PhotoPicker { urls in library.importBatch(urls) }.ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importBatch(urls, securityScoped: true) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $editing) { item in EditorView(item: item) }
        }
    }

    func endSelect() { selecting = false; selection = [] }

    // MARK: Albums

    var albumBar: some View {
        let counts = albumCounts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                albumChip("all", "All Photos", "photo.on.rectangle", library.items.count)
                if library.items.contains(where: \.flagged) { albumChip("flagged", "Flagged", "flag.fill", library.items.filter(\.flagged).count) }
                if library.items.contains(where: { $0.rating > 0 }) { albumChip("rated", "Rated", "star.fill", library.items.filter { $0.rating > 0 }.count) }
                ForEach(smart.categories.filter(\.enabled)) { c in
                    if let n = counts[c.id], n > 0 { albumChip(c.id, c.name, c.icon, n) }
                }
                let unsorted = library.items.filter { $0.analysis == nil }.count
                if unsorted > 0 && !smart.isBusy { albumChip("unsorted", "Not analyzed", "questionmark.circle", unsorted) }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 4)
    }

    func albumChip(_ id: String, _ name: String, _ icon: String, _ count: Int) -> some View {
        let sel = album == id
        return Button { withAnimation(.easeOut(duration: 0.15)) { album = id } } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(name).font(.system(size: 13, weight: .semibold))
                Text("\(count)").font(.system(size: 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(sel ? Color.black.opacity(0.15) : Color.white.opacity(0.1), in: Capsule())
            }
            .foregroundStyle(sel ? .black : .white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(sel ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.panel2), in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: sel ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Status + add button

    var statusPills: some View {
        HStack(spacing: 10) {
            if library.importing {
                pill {
                    ProgressView(value: Double(library.importDone), total: Double(max(library.importTotal, 1))).frame(width: 70).tint(Theme.accent)
                    Text("Importing \(library.importDone)/\(library.importTotal)")
                }
            } else if smart.isBusy {
                pill {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("Sorting \(smart.done)/\(smart.queued)")
                }
            }
            Spacer()
            Menu {
                Button { showPicker = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
                Button { showFiles = true } label: { Label("From Files (RAW, DNG…)", systemImage: "folder") }
            } label: {
                Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 58, height: 58).background(Theme.gradient, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.45), radius: 12, y: 4)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    func pill<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { c() }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke))
    }

    @ViewBuilder func menu(for item: PhotoItem) -> some View {
        Button { library.clipboard = library.settings(for: item) } label: { Label("Copy Settings", systemImage: "doc.on.doc") }
        if let c = library.clipboard {
            Button { library.paste(c, onto: item) } label: { Label("Paste Settings", systemImage: "doc.on.clipboard") }
        }
        Button { var it = item; it.flagged.toggle(); library.update(it) } label: { Label(item.flagged ? "Unflag" : "Flag", systemImage: "flag") }
        Menu("Rating") {
            ForEach(0..<6) { r in
                Button(r == 0 ? "None" : String(repeating: "★", count: r)) { var it = item; it.rating = r; library.update(it) }
            }
        }
        Menu("Add to Album") {
            ForEach(smart.categories) { c in
                let has = item.manualAlbums?.contains(c.id) ?? false
                Button { var it = item; var m = Set(it.manualAlbums ?? []); if has { m.remove(c.id) } else { m.insert(c.id) }; it.manualAlbums = Array(m); library.update(it) } label: {
                    Label(c.name, systemImage: has ? "checkmark" : c.icon)
                }
            }
        }
        if let a = item.analysis {
            Text("Sharpness \(Int(a.sharpness)) · \(smart.albums(for: item).compactMap { id in smart.categories.first { $0.id == id }?.name }.joined(separator: ", "))")
        }
        Button {
            let s = EditSettings.defaults(isRAW: item.isRAW)
            library.saveSettings(s, for: item); library.makeThumbnail(item, settings: s)
        } label: { Label("Reset Edits", systemImage: "arrow.uturn.backward") }
        Button(role: .destructive) { library.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.gradient).frame(width: 110, height: 110).blur(radius: 30).opacity(0.5)
                Image(systemName: "camera.aperture").font(.system(size: 60, weight: .light)).foregroundStyle(Theme.gradient)
            }
            Text("Your photos, developed.").font(.title2.weight(.bold))
            Text("Import RAW, ProRAW, DNG, HEIC or JPEG. Lumora sorts them into smart albums — in focus, sharpest, dunks, celebrations and more.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.text2).padding(.horizontal, 30)
            HStack {
                Button { showPicker = true } label: {
                    Label("Photos", systemImage: "photo.on.rectangle").bold().foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 12).background(Theme.gradient, in: Capsule())
                }
                Button { showFiles = true } label: {
                    Label("Files", systemImage: "folder").bold().foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 12).background(Theme.panel2, in: Capsule())
                }
            }
            if cloud.isConfigured {
                Button("Restore from \(cloud.folderName ?? "cloud")") { cloud.restore() }.padding(.top)
            }
        }.padding()
    }
}

struct Thumb: View {
    @EnvironmentObject var library: LibraryStore
    let item: PhotoItem
    var selected = false
    var selecting = false
    var showScore = false

    var body: some View {
        let _ = library.thumbVersion[item.id]
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = library.thumbnail(item) {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if item.isRAW { Text("RAW").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 2).background(.black.opacity(0.55), in: Capsule()) }
                    if item.flagged { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                    if item.rating > 0 { Text(String(repeating: "★", count: item.rating)).font(.system(size: 8)) }
                    if showScore, let a = item.analysis {
                        Text("\(Int(a.sharpness))").font(.system(size: 9, weight: .bold).monospacedDigit())
                            .padding(.horizontal, 4).padding(.vertical, 1).background(.black.opacity(0.55), in: Capsule())
                    }
                }.padding(4)
            }
            .overlay {
                if selecting {
                    ZStack(alignment: .topTrailing) {
                        if selected { Color.black.opacity(0.35) }
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20)).foregroundStyle(selected ? Theme.accent : .white).padding(5)
                    }
                }
            }
    }
}

/// PHPicker that keeps the original file format (so RAW / ProRAW stays RAW). No photo-library permission needed.
struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ p: PhotoPicker) { parent = p }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }
            let store = LibraryStore.shared
            store.importing = true
            store.importTotal = results.count
            store.importDone = 0
            let group = DispatchGroup()
            var urls: [(Int, URL)] = []
            let lock = NSLock()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for (idx, r) in results.enumerated() {
                let p = r.itemProvider
                let types = p.registeredTypeIdentifiers
                let rawType = types.first { UTType($0)?.conforms(to: .rawImage) == true }
                let imgType = rawType ?? types.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
                group.enter()
                do {
                    p.loadFileRepresentation(forTypeIdentifier: imgType) { url, _ in
                        defer { group.leave() }
                        guard let url else { return }
                        let name = p.suggestedName.map { n -> String in
                            (n as NSString).pathExtension.isEmpty ? n + "." + url.pathExtension : n
                        } ?? url.lastPathComponent
                        let folder = tmp.appendingPathComponent("\(idx)", isDirectory: true)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let dst = folder.appendingPathComponent(name)
                        if (try? FileManager.default.copyItem(at: url, to: dst)) != nil {
                            lock.lock(); urls.append((idx, dst)); lock.unlock()
                        }
                    }
                }
            }
            group.notify(queue: .main) {
                self.parent.onPick(urls.sorted { $0.0 < $1.0 }.map(\.1))
            }
        }
    }
}
