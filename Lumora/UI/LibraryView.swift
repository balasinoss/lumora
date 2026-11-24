import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var cloud: CloudSync
    @State private var showPicker = false
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var editing: PhotoItem?
    @State private var filter = 0   // 0 all, 1 flagged, 2 edited-ish (rated)
    @State private var selecting = false
    @State private var selection: Set<UUID> = []

    private let cols = [GridItem(.adaptive(minimum: 108), spacing: 2)]

    var filtered: [PhotoItem] {
        switch filter {
        case 1: return library.items.filter(\.flagged)
        case 2: return library.items.filter { $0.rating > 0 }
        default: return library.items
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if library.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        Picker("", selection: $filter) {
                            Text("All").tag(0); Text("Flagged").tag(1); Text("Rated").tag(2)
                        }
                        .pickerStyle(.segmented).padding(.horizontal).padding(.top, 4)
                        LazyVGrid(columns: cols, spacing: 2) {
                            ForEach(filtered) { item in
                                Thumb(item: item, selected: selection.contains(item.id), selecting: selecting)
                                    .onTapGesture {
                                        if selecting {
                                            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                                        } else { editing = item }
                                    }
                                    .contextMenu { menu(for: item) }
                            }
                        }
                    }
                }
                if library.importing {
                    ProgressView("Importing…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Lumora")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: cloud.isConfigured ? (cloud.busy > 0 ? "icloud.and.arrow.up" : "checkmark.icloud") : "icloud.slash")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selecting {
                        if library.clipboard != nil && !selection.isEmpty {
                            Button("Paste") {
                                for it in library.items where selection.contains(it.id) { library.paste(library.clipboard!, onto: it) }
                                selecting = false; selection = []
                            }
                        }
                        Button(role: .destructive) {
                            for it in library.items where selection.contains(it.id) { library.delete(it) }
                            selecting = false; selection = []
                        } label: { Image(systemName: "trash") }.disabled(selection.isEmpty)
                        Button("Done") { selecting = false; selection = [] }
                    } else {
                        if !library.items.isEmpty { Button("Select") { selecting = true } }
                        Menu {
                            Button { showPicker = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
                            Button { showFiles = true } label: { Label("From Files (RAW, DNG…)", systemImage: "folder") }
                        } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                PhotoPicker { urls in importURLs(urls) }.ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    library.importing = true
                    for u in urls {
                        let ok = u.startAccessingSecurityScopedResource()
                        library.importFile(at: u)
                        if ok { u.stopAccessingSecurityScopedResource() }
                    }
                    library.importing = false
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $editing) { item in
                EditorView(item: item)
            }
        }
    }

    private func importURLs(_ urls: [URL]) {
        for u in urls { library.importFile(at: u) }
        library.importing = false
    }

    @ViewBuilder func menu(for item: PhotoItem) -> some View {
        Button { library.clipboard = library.settings(for: item) } label: { Label("Copy Settings", systemImage: "doc.on.doc") }
        if let c = library.clipboard {
            Button { library.paste(c, onto: item) } label: { Label("Paste Settings", systemImage: "doc.on.clipboard") }
        }
        Button {
            var it = item; it.flagged.toggle(); library.update(it)
        } label: { Label(item.flagged ? "Unflag" : "Flag", systemImage: "flag") }
        Menu("Rating") {
            ForEach(0..<6) { r in
                Button(r == 0 ? "None" : String(repeating: "★", count: r)) { var it = item; it.rating = r; library.update(it) }
            }
        }
        Button {
            var s = EditSettings.defaults(isRAW: item.isRAW)
            s.crop = .full
            library.saveSettings(s, for: item); library.makeThumbnail(item, settings: s)
        } label: { Label("Reset Edits", systemImage: "arrow.uturn.backward") }
        Button(role: .destructive) { library.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture").font(.system(size: 64)).foregroundStyle(Theme.accent)
            Text("Add photos to start editing").font(.title3.weight(.semibold))
            Text("RAW, ProRAW, DNG, HEIC and JPEG are supported.").foregroundStyle(Theme.text2)
            HStack {
                Button { showPicker = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }.buttonStyle(.borderedProminent)
                Button { showFiles = true } label: { Label("Files", systemImage: "folder") }.buttonStyle(.bordered)
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

    var body: some View {
        let _ = library.thumbVersion[item.id]
        Color(white: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = library.thumbnail(item) {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if item.isRAW { Text("RAW").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1).background(.black.opacity(0.6), in: Capsule()) }
                    if item.flagged { Image(systemName: "flag.fill").font(.system(size: 10)) }
                    if item.rating > 0 { Text(String(repeating: "★", count: item.rating)).font(.system(size: 9)) }
                }.padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.accent : .white).padding(5)
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
            LibraryStore.shared.importing = true
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for r in results {
                let p = r.itemProvider
                // Prefer RAW, then the original HEIC/JPEG.
                let types = p.registeredTypeIdentifiers
                let rawType = types.first { UTType($0)?.conforms(to: .rawImage) == true }
                let imgType = rawType ?? types.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
                group.enter()
                p.loadFileRepresentation(forTypeIdentifier: imgType) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    let name = p.suggestedName.map { n -> String in
                        (n as NSString).pathExtension.isEmpty ? n + "." + url.pathExtension : n
                    } ?? url.lastPathComponent
                    let dst = tmp.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: dst)
                    if (try? FileManager.default.copyItem(at: url, to: dst)) != nil {
                        lock.lock(); urls.append(dst); lock.unlock()
                    }
                }
            }
            group.notify(queue: .main) { self.parent.onPick(urls) }
        }
    }
}
