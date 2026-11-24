import SwiftUI
import UIKit
import CoreImage

final class EditorModel: ObservableObject {
    let item: PhotoItem
    let source: PhotoSource?

    @Published var settings: EditSettings {
        didSet { if settings != oldValue { scheduleRender(); scheduleSave() } }
    }
    @Published var preview: UIImage?
    @Published var original: UIImage?
    @Published var histogram: [[Float]] = []
    @Published var cropMode = false { didSet { if cropMode != oldValue { scheduleRender() } } }
    /// Masking tool active: show the photo in its original frame
    @Published var maskMode = false { didSet { if maskMode != oldValue { scheduleRender() } } }
    @Published var selectedMaskID: UUID? { didSet { if selectedMaskID != oldValue { scheduleRender() } } }
    @Published var showMaskOverlay = true { didSet { scheduleRender() } }
    @Published var brushMode: BrushMode = .off
    @Published var brushSize: Double = 0.06
    @Published var brushFeather: Double = 0.5
    @Published var brushFlow: Double = 1.0
    @Published var maskBusy: String?
    @Published var maskError: String?
    @Published var peopleCount: Int?
    /// Light → Curve: edit the curve directly on the photo
    @Published var curveEditing = false
    @Published var curveChannel: CurveChannel = .master
    /// Detail → Masking preview
    @Published var showSharpenMask = false { didSet { if showSharpenMask != oldValue { scheduleRender() } } }
    /// AI Denoise
    @Published var denoiseProgress: Double?
    @Published var denoiseApplied: Double?
    @Published var denoiseError: String?

    enum BrushMode { case off, add, erase }
    var itemDir: URL { LibraryStore.shared.dir(item) }
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var matchedLens: LensProfile?
    @Published var lensSearchDone = false

    private var undoStack: [EditSettings] = []
    private var redoStack: [EditSettings] = []
    private var committed: EditSettings
    private var rendering = false
    private var pending = false
    private var saveWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "lumora.render", qos: .userInitiated)
    private let pipeline = RenderPipeline.shared

    init(item: PhotoItem) {
        self.item = item
        let s = LibraryStore.shared.settings(for: item)
        settings = s
        committed = s
        source = PhotoSource(url: LibraryStore.shared.originalURL(item))
        denoiseApplied = AIDenoise.appliedAmount(LibraryStore.shared.dir(item))
        scheduleRender()
        findLens()
    }

    // MARK: Undo

    /// Call when a gesture/edit finishes.
    func commit() {
        guard settings != committed else { return }
        undoStack.append(committed)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        committed = settings
        canUndo = true; canRedo = false
    }
    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(settings)
        settings = prev; committed = prev
        canUndo = !undoStack.isEmpty; canRedo = true
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        settings = next; committed = next
        canUndo = true; canRedo = !redoStack.isEmpty
    }
    func reset() {
        settings = .defaults(isRAW: item.isRAW)
        commit()
    }
    /// Apply a change and commit it in one go (buttons, toggles, pickers).
    func edit(_ change: (inout EditSettings) -> Void) {
        var s = settings
        change(&s)
        settings = s
        commit()
    }

    // MARK: Rendering

    func scheduleRender() {
        if rendering { pending = true; return }
        rendering = true
        let s = settings
        let mode: RenderMode = cropMode ? .crop : (maskMode ? .mask : .normal)
        let overlay = (maskMode && showMaskOverlay) ? selectedMaskID : nil
        let sharpenMask = showSharpenMask
        queue.async { [weak self] in
            guard let self else { return }
            let out = self.render(s, mode: mode, overlay: overlay, sharpenMask: sharpenMask)
            DispatchQueue.main.async {
                if let out {
                    self.preview = out.0
                    self.histogram = out.1
                }
                self.rendering = false
                if self.pending { self.pending = false; self.scheduleRender() }
            }
        }
    }

    enum RenderMode { case normal, crop, mask }

    private func render(_ s: EditSettings, mode: RenderMode, overlay: UUID?, sharpenMask: Bool) -> (UIImage, [[Float]])? {
        guard let source, let base = source.previewBase(settings: s, context: pipeline.context) else { return nil }
        let full = min(source.fullSize.width, source.fullSize.height)
        var info = RenderPipeline.info(for: source, settings: s, pixelScale: min(base.extent.width, base.extent.height) / max(full, 1))
        info.overlayMask = overlay
        info.sharpenMaskPreview = sharpenMask
        let img: CIImage
        switch mode {
        case .crop: img = pipeline.processUncropped(base, settings: s, info: info)
        case .mask: img = pipeline.processUnframed(base, settings: s, info: info)
        case .normal: img = pipeline.process(base, settings: s, info: info)
        }
        guard let cg = pipeline.cgImage(img) else { return nil }
        return (UIImage(cgImage: cg), pipeline.histogram(img))
    }

    func loadOriginal() {
        guard original == nil else { return }
        let isRAW = item.isRAW
        queue.async { [weak self] in
            guard let self, let source = self.source,
                  let base = source.previewBase(settings: .defaults(isRAW: isRAW), context: self.pipeline.context) else { return }
            var s = EditSettings.defaults(isRAW: isRAW)
            s.sharpening = 0; s.colorNoiseReduction = 0
            let info = RenderPipeline.info(for: source, settings: s, pixelScale: 0.5)
            if let cg = self.pipeline.cgImage(self.pipeline.process(base, settings: s, info: info)) {
                DispatchQueue.main.async { self.original = UIImage(cgImage: cg) }
            }
        }
    }

    // MARK: Lens

    func findLens() {
        guard let source else { lensSearchDone = true; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lens = LensDatabase.shared.match(lensModel: source.lensModel, lensMake: source.lensMake, cameraMake: source.cameraMake)
            DispatchQueue.main.async { self?.matchedLens = lens; self?.lensSearchDone = true }
        }
    }

    var activeLens: LensProfile? {
        if let id = settings.lensProfileID { return LensDatabase.shared.lens(id: id) }
        return matchedLens
    }

    // MARK: Auto

    func autoTone() {
        guard let source else { return }
        let a = source.averageColor(context: pipeline.context)
        let l = max(0.002, a[0] * 0.2126 + a[1] * 0.7152 + a[2] * 0.0722)
        let ev = max(-2.5, min(2.5, log2(0.16 / l) * 0.75))
        edit {
            $0.exposure = (ev * 100).rounded() / 100
            $0.contrast = 10; $0.highlights = -35; $0.shadows = 30
            $0.whites = 8; $0.blacks = -8; $0.vibrance = 12; $0.saturation = 3
        }
    }

    // MARK: Masks

    var selectedMask: MaskLayer? {
        get { settings.masks.first { $0.id == selectedMaskID } }
    }
    func updateMask(_ change: (inout MaskLayer) -> Void) {
        guard let i = settings.masks.firstIndex(where: { $0.id == selectedMaskID }) else { return }
        var m = settings.masks[i]
        change(&m)
        settings.masks[i] = m
    }
    func maskBinding(_ kp: WritableKeyPath<LocalAdjust, Double>) -> Binding<Double> {
        Binding(get: { self.selectedMask?.adjust[keyPath: kp] ?? 0 },
                set: { v in self.updateMask { $0.adjust[keyPath: kp] = v } })
    }

    func addMask(_ kind: MaskKind, personIndex: Int = 0) {
        let name = kind == .person ? "Person \(personIndex + 1)" : kind.title
        let layer = MaskLayer(kind: kind, name: name, personIndex: personIndex)
        func insert() {
            edit { $0.masks.append(layer) }
            selectedMaskID = layer.id
            brushMode = kind == .brush ? .add : .off
        }
        guard kind.isAI, let source else { insert(); return }
        if MaskEngine.shared.hasMask(itemDir, kind: kind, personIndex: personIndex) { insert(); return }
        maskBusy = "Finding \(name.lowercased())…"
        maskError = nil
        let dir = itemDir
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MaskEngine.shared.generate(kind: kind, personIndex: personIndex, source: source, itemDir: dir)
                DispatchQueue.main.async { self.maskBusy = nil; insert() }
            } catch {
                DispatchQueue.main.async { self.maskBusy = nil; self.maskError = error.localizedDescription }
            }
        }
    }

    func detectPeople() {
        guard peopleCount == nil, let source else { return }
        let dir = itemDir
        DispatchQueue.global(qos: .userInitiated).async {
            let n = MaskEngine.shared.detectPeople(source: source, itemDir: dir)
            DispatchQueue.main.async { self.peopleCount = n }
        }
    }

    func deleteMask(_ id: UUID) {
        edit { $0.masks.removeAll { $0.id == id } }
        if selectedMaskID == id { selectedMaskID = nil }
    }

    func duplicateMask(_ id: UUID, invert: Bool) {
        guard var m = settings.masks.first(where: { $0.id == id }) else { return }
        m.id = UUID()
        m.name += invert ? " (inverted)" : " copy"
        if invert { m.invert.toggle() }
        edit { $0.masks.append(m) }
        selectedMaskID = m.id
    }

    /// Brush painting (normalised image coordinates)
    func beginStroke(at p: NPoint) {
        guard brushMode != .off else { return }
        let stroke = BrushStroke(points: [p], size: brushSize, feather: brushFeather, flow: brushFlow, erase: brushMode == .erase)
        updateMask { $0.strokes.append(stroke) }
    }
    func continueStroke(to p: NPoint) {
        updateMask { m in
            guard var last = m.strokes.popLast() else { return }
            if let q = last.points.last, hypot(q.x - p.x, q.y - p.y) < 0.004 { m.strokes.append(last); return }
            last.points.append(p)
            m.strokes.append(last)
        }
    }

    // MARK: AI Denoise

    func runDenoise(amount: Double) {
        guard let source, denoiseProgress == nil else { return }
        denoiseProgress = 0
        denoiseError = nil
        let s = settings, dir = itemDir
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AIDenoise.run(source: source, settings: s, itemDir: dir, amount: amount) { p in
                    DispatchQueue.main.async { self.denoiseProgress = p }
                }
                source.clearCache()
                DispatchQueue.main.async {
                    self.denoiseProgress = nil
                    self.denoiseApplied = amount
                    self.edit { $0.aiDenoise = true; $0.aiDenoiseAmount = amount; $0.noiseReduction = 0; $0.colorNoiseReduction = 0 }
                    self.scheduleRender()
                }
            } catch {
                DispatchQueue.main.async { self.denoiseProgress = nil; self.denoiseError = error.localizedDescription }
            }
        }
    }

    func removeDenoise() {
        AIDenoise.remove(itemDir)
        source?.clearCache()
        denoiseApplied = nil
        edit { $0.aiDenoise = false }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let s = settings, item = item
        let w = DispatchWorkItem { LibraryStore.shared.saveSettings(s, for: item) }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    /// Called when leaving the editor.
    func finish() {
        saveWork?.cancel()
        LibraryStore.shared.saveSettings(settings, for: item)
        LibraryStore.shared.makeThumbnail(item, settings: settings)
        CloudSync.shared.backup(item: item, settings: settings, exportJPEG: true)
    }

    // MARK: Export

    func export(format: RenderPipeline.ExportFormat, quality: Double, maxLongEdge: CGFloat?, completion: @escaping (URL?) -> Void) {
        guard let source else { completion(nil); return }
        let s = settings, name = (item.name as NSString).deletingPathExtension
        DispatchQueue.global(qos: .userInitiated).async {
            let pipeline = RenderPipeline.shared
            guard let img = pipeline.renderFull(source: source, settings: s),
                  let data = pipeline.encode(img, format: format, quality: quality, maxLongEdge: maxLongEdge, properties: source.properties) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let ext = format == .jpeg ? "jpg" : format.rawValue.lowercased()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-edit.\(ext)")
            try? data.write(to: url, options: .atomic)
            DispatchQueue.main.async { completion(url) }
        }
    }
}
