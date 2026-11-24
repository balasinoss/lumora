import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhotoItem: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String            // original file name
    var ext: String
    var added: Date
    var isRAW: Bool
    var rating: Int = 0
    var flagged: Bool = false
}

/// Stores photos in Documents/Library/<id>/ (original.<ext>, edits.json, item.json, thumb.jpg).
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published private(set) var items: [PhotoItem] = []
    @Published var thumbVersion: [UUID: Int] = [:]
    @Published var importing = false
    @Published var clipboard: EditSettings?

    let root: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { reload() }

    func dir(_ item: PhotoItem) -> URL { root.appendingPathComponent(item.id.uuidString, isDirectory: true) }
    func originalURL(_ item: PhotoItem) -> URL { dir(item).appendingPathComponent("original.\(item.ext)") }
    func editsURL(_ item: PhotoItem) -> URL { dir(item).appendingPathComponent("edits.json") }
    func thumbURL(_ item: PhotoItem) -> URL { dir(item).appendingPathComponent("thumb.jpg") }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var list: [PhotoItem] = []
        for d in dirs {
            if let data = try? Data(contentsOf: d.appendingPathComponent("item.json")),
               let item = try? JSONDecoder().decode(PhotoItem.self, from: data) { list.append(item) }
        }
        items = list.sorted { $0.added > $1.added }
    }

    private func saveItem(_ item: PhotoItem) {
        if let data = try? JSONEncoder().encode(item) {
            try? data.write(to: dir(item).appendingPathComponent("item.json"), options: .atomic)
        }
    }

    func update(_ item: PhotoItem) {
        saveItem(item)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
        CloudSync.shared.backup(item: item, settings: nil, exportJPEG: false)
    }

    // MARK: Import

    /// Copies a file into the library. Returns the new item.
    @discardableResult
    func importFile(at url: URL, id: UUID = UUID(), settings: EditSettings? = nil, added: Date = Date(), backup: Bool = true) -> PhotoItem? {
        let fm = FileManager.default
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty { ext = "jpg" }
        let isRAW = PhotoSource.rawTypes.contains(ext) || (UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false)
        let item = PhotoItem(id: id, name: url.lastPathComponent, ext: ext, added: added, isRAW: isRAW)
        do {
            try fm.createDirectory(at: dir(item), withIntermediateDirectories: true)
            if fm.fileExists(atPath: originalURL(item).path) { try fm.removeItem(at: originalURL(item)) }
            try fm.copyItem(at: url, to: originalURL(item))
        } catch {
            return nil
        }
        saveItem(item)
        let s = settings ?? EditSettings.defaults(isRAW: isRAW)
        saveSettings(s, for: item)
        items.insert(item, at: 0)
        items.sort { $0.added > $1.added }
        makeThumbnail(item, settings: s)
        if backup { CloudSync.shared.backup(item: item, settings: s, exportJPEG: false, includeOriginal: true) }
        return item
    }

    func delete(_ item: PhotoItem) {
        try? FileManager.default.removeItem(at: dir(item))
        items.removeAll { $0.id == item.id }
    }

    // MARK: Settings

    func settings(for item: PhotoItem) -> EditSettings {
        if let data = try? Data(contentsOf: editsURL(item)), let s = EditSettings.decode(data) { return s }
        return .defaults(isRAW: item.isRAW)
    }

    func saveSettings(_ s: EditSettings, for item: PhotoItem) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: editsURL(item), options: .atomic) }
    }

    func paste(_ s: EditSettings, onto item: PhotoItem) {
        var new = s
        let old = settings(for: item)
        // keep per-photo things
        new.crop = old.crop; new.straighten = old.straighten; new.rotation90 = old.rotation90
        new.lensProfileID = old.lensProfileID
        if !item.isRAW && new.whiteBalance != "As Shot" && new.whiteBalance != "Auto" { new.whiteBalance = "As Shot" }
        saveSettings(new, for: item)
        makeThumbnail(item, settings: new)
        CloudSync.shared.backup(item: item, settings: new, exportJPEG: true)
    }

    // MARK: Thumbnails

    func makeThumbnail(_ item: PhotoItem, settings: EditSettings) {
        let url = originalURL(item), turl = thumbURL(item)
        DispatchQueue.global(qos: .utility).async {
            guard let src = PhotoSource(url: url),
                  let img = RenderPipeline.shared.renderFull(source: src, settings: settings, maxDimension: 600),
                  let data = RenderPipeline.shared.encode(img, format: .jpeg, quality: 0.8, maxLongEdge: 600, properties: [:]) else { return }
            try? data.write(to: turl, options: .atomic)
            DispatchQueue.main.async { self.thumbVersion[item.id, default: 0] += 1 }
        }
    }

    func thumbnail(_ item: PhotoItem) -> UIImage? { UIImage(contentsOfFile: thumbURL(item).path) }
}

// MARK: - iCloud Drive (or any Files folder) sync

/// The user picks a folder once (e.g. iCloud Drive/Lumora). From then on Lumora writes:
///   <folder>/Library/<id>/original.ext + edits.json + item.json  (full backup, restorable)
///   <folder>/Edited/<name>.jpg                                   (finished photos)
/// Works without a paid developer account because it uses a user-granted folder bookmark.
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published private(set) var folderName: String?
    @Published var autoExport: Bool { didSet { UserDefaults.standard.set(autoExport, forKey: "autoExport") } }
    @Published var backupOriginals: Bool { didSet { UserDefaults.standard.set(backupOriginals, forKey: "backupOriginals") } }
    @Published var exportQuality: Double { didSet { UserDefaults.standard.set(exportQuality, forKey: "exportQuality") } }
    @Published private(set) var lastStatus: String = ""
    @Published private(set) var busy = 0

    private let queue = DispatchQueue(label: "lumora.cloud", qos: .utility)
    private let bookmarkKey = "cloudFolderBookmark"

    init() {
        let d = UserDefaults.standard
        autoExport = d.object(forKey: "autoExport") as? Bool ?? true
        backupOriginals = d.object(forKey: "backupOriginals") as? Bool ?? true
        exportQuality = d.object(forKey: "exportQuality") as? Double ?? 0.92
        folderName = resolveFolder()?.lastPathComponent
    }

    var isConfigured: Bool { folderName != nil }

    func setFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            folderName = url.lastPathComponent
            lastStatus = "Connected to \(url.lastPathComponent)"
        } else {
            lastStatus = "Could not save access to that folder"
        }
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        folderName = nil
    }

    func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "cloudFolderBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "cloudFolderBookmark")
        }
        return url
    }

    private func coordinatedWrite(_ data: Data, to url: URL) {
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            try? data.write(to: u, options: .atomic)
        }
    }

    private func coordinatedCopy(_ src: URL, to dst: URL) {
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &err) { u in
            try? FileManager.default.removeItem(at: u)
            try? FileManager.default.copyItem(at: src, to: u)
        }
    }

    /// Backs up an item. settings == nil → only item.json.
    func backup(item: PhotoItem, settings: EditSettings?, exportJPEG: Bool, includeOriginal: Bool = false) {
        guard isConfigured else { return }
        let store = LibraryStore.shared
        let original = store.originalURL(item)
        let itemJSON = try? JSONEncoder().encode(item)
        let editsJSON = settings.flatMap { try? JSONEncoder().encode($0) }
        let doOriginal = includeOriginal && backupOriginals
        let doExport = exportJPEG && autoExport
        let quality = exportQuality
        busy += 1
        queue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.busy -= 1 } }
            guard let folder = self.resolveFolder() else { return }
            let ok = folder.startAccessingSecurityScopedResource()
            defer { if ok { folder.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let libDir = folder.appendingPathComponent("Library/\(item.id.uuidString)", isDirectory: true)
            try? fm.createDirectory(at: libDir, withIntermediateDirectories: true)
            if let itemJSON { self.coordinatedWrite(itemJSON, to: libDir.appendingPathComponent("item.json")) }
            if let editsJSON { self.coordinatedWrite(editsJSON, to: libDir.appendingPathComponent("edits.json")) }
            let dstOriginal = libDir.appendingPathComponent("original.\(item.ext)")
            if (doOriginal || self.backupOriginalsNonisolated) && !fm.fileExists(atPath: dstOriginal.path) {
                self.coordinatedCopy(original, to: dstOriginal)
            }
            var status = "Backed up \(item.name)"
            if doExport, let settings {
                if let src = PhotoSource(url: original),
                   let img = RenderPipeline.shared.renderFull(source: src, settings: settings),
                   let data = RenderPipeline.shared.encode(img, format: .jpeg, quality: quality, maxLongEdge: nil, properties: src.properties) {
                    let edited = folder.appendingPathComponent("Edited", isDirectory: true)
                    try? fm.createDirectory(at: edited, withIntermediateDirectories: true)
                    let base = (item.name as NSString).deletingPathExtension
                    self.coordinatedWrite(data, to: edited.appendingPathComponent("\(base).jpg"))
                    status = "Saved \(base).jpg to \(folder.lastPathComponent)"
                }
            }
            DispatchQueue.main.async { self.lastStatus = status }
        }
    }

    private var backupOriginalsNonisolated: Bool {
        UserDefaults.standard.object(forKey: "backupOriginals") as? Bool ?? true
    }

    /// Imports photos that exist in the cloud folder but not on this phone (e.g. after reinstalling).
    func restore() {
        guard isConfigured else { return }
        let existing = Set(LibraryStore.shared.items.map(\.id))
        busy += 1
        queue.async { [weak self] in
            guard let self else { return }
            guard let folder = self.resolveFolder() else { DispatchQueue.main.async { self.busy -= 1 }; return }
            let ok = folder.startAccessingSecurityScopedResource()
            let lib = folder.appendingPathComponent("Library", isDirectory: true)
            let dirs = (try? FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)) ?? []
            var found: [(PhotoItem, URL, EditSettings?)] = []
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("restore", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for d in dirs {
                guard let data = try? Data(contentsOf: d.appendingPathComponent("item.json")),
                      let item = try? JSONDecoder().decode(PhotoItem.self, from: data),
                      !existing.contains(item.id) else { continue }
                let orig = d.appendingPathComponent("original.\(item.ext)")
                // make sure iCloud has downloaded the file
                try? FileManager.default.startDownloadingUbiquitousItem(at: orig)
                var err: NSError?
                var local: URL?
                NSFileCoordinator().coordinate(readingItemAt: orig, options: [], error: &err) { u in
                    let dst = tmp.appendingPathComponent("\(item.id.uuidString).\(item.ext)")
                    try? FileManager.default.removeItem(at: dst)
                    if (try? FileManager.default.copyItem(at: u, to: dst)) != nil { local = dst }
                }
                let edits = (try? Data(contentsOf: d.appendingPathComponent("edits.json"))).flatMap(EditSettings.decode)
                if let local { found.append((item, local, edits)) }
            }
            if ok { folder.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                for (item, url, edits) in found {
                    var renamed = url
                    let named = url.deletingLastPathComponent().appendingPathComponent(item.name)
                    if (try? FileManager.default.moveItem(at: url, to: named)) != nil { renamed = named }
                    LibraryStore.shared.importFile(at: renamed, id: item.id, settings: edits, added: item.added, backup: false)
                }
                self.lastStatus = found.isEmpty ? "Everything is already on this iPhone" : "Restored \(found.count) photo(s)"
                self.busy -= 1
            }
        }
    }
}
