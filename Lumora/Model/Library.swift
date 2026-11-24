import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO
import CoreImage

struct PhotoItem: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String            // original file name
    var ext: String
    var added: Date
    var isRAW: Bool
    var rating: Int = 0
    var flagged: Bool = false
    /// Smart-sort results (nil until analysed)
    var analysis: PhotoAnalysis? = nil
    /// Albums the user added this photo to by hand
    var manualAlbums: [String]? = nil
    /// When the photo was taken (EXIF), for burst grouping
    var captured: Date? = nil
    var rejected: Bool? = nil
    var isRejected: Bool { rejected ?? false }
}

struct PhotoAnalysis: Codable, Equatable, Hashable {
    var sharpness: Double = 0          // 0...100, subject sharpness
    var backgroundSharpness: Double = 0
    var faces: Int = 0
    var people: Int = 0
    var largestFace: Double = 0        // face height / image height
    var armsUp: Bool = false
    var clipScores: [String: Double] = [:]   // category id -> probability
    var version: Int = 1
    var faceQuality: Double? = nil           // 0...1, Vision face capture quality (eyes open, sharp face)
    var jerseys: [Int]? = nil                // jersey numbers read from the photo
}

/// Stores photos in Documents/Library/<id>/ (original.<ext>, edits.json, item.json, thumb.jpg).
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published private(set) var items: [PhotoItem] = []
    @Published var thumbVersion: [UUID: Int] = [:]
    @Published var importing = false
    @Published var importTotal = 0
    @Published var importDone = 0
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

    func update(_ item: PhotoItem, backup: Bool = true) {
        saveItem(item)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
        if backup { CloudSync.shared.backup(item: item, settings: nil, exportJPEG: false) }
    }

    /// Imports many files; quick thumbnails first, then smart sorting in the background.
    func importBatch(_ urls: [URL], securityScoped: Bool = false) {
        guard !urls.isEmpty else { return }
        importing = true
        importTotal = urls.count
        importDone = 0
        var added: [PhotoItem] = []
        func step(_ i: Int) {
            guard i < urls.count else {
                importing = false
                if SmartSort.shared.autoAnalyze { SmartSort.shared.enqueue(added) }
                return
            }
            let u = urls[i]
            let ok = securityScoped ? u.startAccessingSecurityScopedResource() : false
            if let item = importFile(at: u) { added.append(item) }
            if ok { u.stopAccessingSecurityScopedResource() }
            importDone = i + 1
            // yield to the UI between files
            DispatchQueue.main.async { step(i + 1) }
        }
        step(0)
    }

    // MARK: Import

    /// Copies a file into the library. Returns the new item.
    @discardableResult
    func importFile(at url: URL, id: UUID = UUID(), settings: EditSettings? = nil, added: Date = Date(), backup: Bool = true) -> PhotoItem? {
        let fm = FileManager.default
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty { ext = "jpg" }
        let isRAW = PhotoSource.rawTypes.contains(ext) || (UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false)
        var item = PhotoItem(id: id, name: url.lastPathComponent, ext: ext, added: added, isRAW: isRAW)
        item.captured = LibraryStore.captureDate(url)
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
        if settings == nil { makeQuickThumbnail(item) } else { makeThumbnail(item, settings: s) }
        if backup { CloudSync.shared.backup(item: item, settings: s, exportJPEG: false, includeOriginal: true) }
        return item
    }

    static func captureDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        guard let str = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard var d = f.date(from: str) else { return nil }
        if let sub = exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String, let frac = Double("0." + sub) {
            d.addTimeInterval(frac)
        }
        return d
    }

    // MARK: Bursts & culling

    /// Groups photos shot within `gap` seconds of each other (2+ photos per burst), newest first.
    func bursts(gap: TimeInterval = 1.0) -> [[PhotoItem]] {
        let dated = items.filter { $0.captured != nil }.sorted { $0.captured! < $1.captured! }
        var groups: [[PhotoItem]] = []
        var cur: [PhotoItem] = []
        for it in dated {
            if let last = cur.last, it.captured!.timeIntervalSince(last.captured!) > gap {
                if cur.count > 1 { groups.append(cur) }
                cur = []
            }
            cur.append(it)
        }
        if cur.count > 1 { groups.append(cur) }
        return groups.reversed()
    }

    /// Score used to pick the best frame of a burst.
    static func keeperScore(_ it: PhotoItem) -> Double {
        guard let a = it.analysis else { return 0 }
        return a.sharpness + (a.faceQuality ?? 0.3) * 25 + (it.flagged ? 100 : 0)
    }

    func bestOf(_ burst: [PhotoItem]) -> PhotoItem? { burst.max { LibraryStore.keeperScore($0) < LibraryStore.keeperScore($1) } }

    /// Keeps the best frame of each burst and rejects the rest.
    func keepBest(_ burstsToCull: [[PhotoItem]]) {
        for b in burstsToCull {
            guard let best = bestOf(b) else { continue }
            for var it in b {
                it.rejected = it.id != best.id
                if it.id == best.id { it.flagged = true }
                update(it, backup: false)
            }
        }
    }

    func setPick(_ item: PhotoItem, picked: Bool?) {
        var it = item
        switch picked {
        case .some(true): it.flagged = true; it.rejected = false
        case .some(false): it.flagged = false; it.rejected = true
        case .none: it.flagged = false; it.rejected = false
        }
        update(it, backup: false)
    }

    // MARK: Presets on many photos

    func applyPreset(_ preset: Preset, amount: Double = 1, to targets: [PhotoItem]) {
        for it in targets {
            let s = PresetStore.apply(preset, amount: amount, to: settings(for: it))
            saveSettings(s, for: it)
            makeThumbnail(it, settings: s)
            CloudSync.shared.backup(item: it, settings: s, exportJPEG: true)
        }
    }

    // MARK: Match exposure & white balance to a reference photo

    private func meanColor(_ item: PhotoItem, _ s: EditSettings) -> [Double]? {
        guard let src = PhotoSource(url: originalURL(item)),
              let img = RenderPipeline.shared.renderFull(source: src, settings: s, maxDimension: 384) else { return nil }
        let ctx = RenderPipeline.shared.context
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
        var px = [Float](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                   colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return [Double(px[0]), Double(px[1]), Double(px[2])].map { max($0, 1e-4) }
    }

    func match(reference: PhotoItem, targets: [PhotoItem], progress: @escaping (Int) -> Void, done: @escaping () -> Void) {
        let refSettings = settings(for: reference)
        let targetsWithSettings = targets.filter { $0.id != reference.id }.map { ($0, settings(for: $0)) }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let ref = self.meanColor(reference, refSettings) else { DispatchQueue.main.async { done() }; return }
            func luma(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
            var n = 0
            for (item, start) in targetsWithSettings {
                var s = start
                for _ in 0..<3 {
                    guard let c = self.meanColor(item, s) else { break }
                    let dEV = log2(luma(ref) / luma(c))
                    s.exposure = min(5, max(-5, s.exposure + dEV * 0.9))
                    // blue/red balance -> temperature, green -> tint
                    let warm = log2((c[2] / c[0]) / (ref[2] / ref[0]))        // > 0: target is too blue
                    let green = log2((c[1] / ((c[0] + c[2]) / 2)) / (ref[1] / ((ref[0] + ref[2]) / 2)))
                    if item.isRAW {
                        let src = PhotoSource(url: self.originalURL(item))
                        let (t, ti) = src?.rawWhiteBalance(s) ?? (5500, 0)
                        s.whiteBalance = "Custom"
                        s.temperature = min(12000, max(2000, t * pow(2, warm * 0.55)))
                        s.tint = min(150, max(-150, ti + green * 90))
                    } else {
                        s.whiteBalance = "Custom"
                        s.tempShift = min(100, max(-100, s.tempShift + warm * 45))
                        s.tint = min(100, max(-100, s.tint + green * 70))
                    }
                }
                DispatchQueue.main.async {
                    self.saveSettings(s, for: item)
                    self.makeThumbnail(item, settings: s)
                    n += 1
                    progress(n)
                }
            }
            DispatchQueue.main.async { done() }
        }
    }

    // MARK: Versions

    struct Version: Codable, Identifiable {
        var id = UUID()
        var name: String
        var date = Date()
        var settings: EditSettings
    }
    func versionsURL(_ item: PhotoItem) -> URL { dir(item).appendingPathComponent("versions.json") }
    func versions(_ item: PhotoItem) -> [Version] {
        guard let d = try? Data(contentsOf: versionsURL(item)) else { return [] }
        return (try? JSONDecoder().decode([Version].self, from: d)) ?? []
    }
    func saveVersions(_ v: [Version], for item: PhotoItem) {
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: versionsURL(item), options: .atomic) }
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
            DispatchQueue.main.async { self.thumbCache.removeObject(forKey: item.id as NSUUID); self.thumbVersion[item.id, default: 0] += 1 }
        }
    }

    /// Fast thumbnail from the file's embedded preview (used on import).
    func makeQuickThumbnail(_ item: PhotoItem) {
        let url = originalURL(item), turl = thumbURL(item)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = PhotoSource(url: url), let cg = src.quickImage(maxPixel: 600),
                  let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return }
            try? data.write(to: turl, options: .atomic)
            DispatchQueue.main.async { self.thumbCache.removeObject(forKey: item.id as NSUUID); self.thumbVersion[item.id, default: 0] += 1 }
        }
    }

    private let thumbCache = NSCache<NSUUID, UIImage>()
    func thumbnail(_ item: PhotoItem) -> UIImage? {
        if let c = thumbCache.object(forKey: item.id as NSUUID) { return c }
        guard let img = UIImage(contentsOfFile: thumbURL(item).path) else { return nil }
        thumbCache.setObject(img, forKey: item.id as NSUUID)
        return img
    }
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
