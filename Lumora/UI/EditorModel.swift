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
    /// Edit history (oldest first) with a readable label per step
    @Published var history: [(label: String, settings: EditSettings)] = []
    @Published var historyIndex = 0
    // Presets
    @Published var activePreset: Preset?
    @Published var presetAmount: Double = 100
    private var presetBase: EditSettings?
    // Eyedropper for point colour
    @Published var pickingColor = false
    @Published var selectedPointID: UUID?
    // Healing
    @Published var selectedHealID: UUID?
    @Published var healSize: Double = 0.04
    @Published var healClone = false
    // Select Object: drawing a rectangle
    @Published var drawingObject = false
    // Versions
    @Published var versions: [LibraryStore.Version] = []
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
        history = [("Original import", s)]
        versions = LibraryStore.shared.versions(item)
        source = PhotoSource(url: LibraryStore.shared.originalURL(item))
        denoiseApplied = AIDenoise.appliedAmount(LibraryStore.shared.dir(item))
        scheduleRender()
        findLens()
    }

    // MARK: Undo

    /// Call when a gesture/edit finishes.
    func commit() {
        guard settings != committed else { return }
        let label = EditorModel.describeChange(from: committed, to: settings)
        undoStack.append(committed)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        committed = settings
        canUndo = true; canRedo = false
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        history.append((label, settings))
        if history.count > 150 { history.removeFirst() }
        historyIndex = history.count - 1
    }

    func jumpToHistory(_ i: Int) {
        guard i >= 0 && i < history.count else { return }
        undoStack.append(settings); redoStack.removeAll()
        settings = history[i].settings
        committed = settings
        historyIndex = i
        canUndo = true; canRedo = false
    }

    /// "Exposure +0.50", "Mixer: Orange saturation −20", …
    static func describeChange(from a: EditSettings, to b: EditSettings) -> String {
        func flat(_ s: EditSettings) -> [String: String] {
            guard let d = try? JSONEncoder().encode(s), let root = try? JSONSerialization.jsonObject(with: d) else { return [:] }
            var out: [String: String] = [:]
            func walk(_ n: Any, _ p: String) {
                if let dict = n as? [String: Any] { for (k, v) in dict { walk(v, p.isEmpty ? k : p + "." + k) } }
                else if let arr = n as? [Any] { for (i, v) in arr.enumerated() { walk(v, p + "." + String(i)) } }
                else { out[p] = "\(n)" }
            }
            walk(root, "")
            return out
        }
        let fa = flat(a), fb = flat(b)
        let changed = Set(fa.keys).union(fb.keys).filter { fa[$0] != fb[$0] }.sorted()
        guard let key = changed.first else { return "Edit" }
        let top = String(key.split(separator: ".").first ?? "")
        let names: [String: String] = [
            "masks": "Mask", "healSpots": "Heal", "pointColors": "Point Color", "crop": "Crop", "mixer": "Color Mixer",
            "curveMaster": "Curve", "curveRed": "Red Curve", "curveGreen": "Green Curve", "curveBlue": "Blue Curve",
            "gradeShadows": "Grading Shadows", "gradeMidtones": "Grading Midtones", "gradeHighlights": "Grading Highlights",
            "gradeGlobal": "Grading Global", "bwMix": "B&W Mix", "aiDenoise": "AI Denoise", "profile": "Look"]
        var name = names[top] ?? top.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
        if changed.count > 3 && !["masks", "mixer", "healSpots", "crop"].contains(top) { name = "Multiple changes" }
        if changed.count == 1, let v = fb[key], let d = Double(v), !["masks", "healSpots", "pointColors"].contains(top) {
            let fmt = abs(d) < 10 && d != d.rounded() ? String(format: "%+.2f", d) : String(format: "%+.0f", d)
            return "\(name) \(fmt)"
        }
        return name
    }
    func undo() {
        guard let prev = undoStack.popLast() else { return }
        if historyIndex > 0 { historyIndex -= 1 }
        redoStack.append(settings)
        settings = prev; committed = prev
        canUndo = !undoStack.isEmpty; canRedo = true
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        if historyIndex < history.count - 1 { historyIndex += 1 }
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

    // MARK: Presets

    func applyPreset(_ p: Preset) {
        if activePreset == nil || presetBase == nil { presetBase = settings }
        activePreset = p
        presetAmount = 100
        settings = PresetStore.apply(p, amount: 1, to: presetBase!)
        commit()
    }
    func setPresetAmount(_ a: Double) {
        guard let p = activePreset, let base = presetBase else { return }
        presetAmount = a
        settings = PresetStore.apply(p, amount: a / 100, to: base)
    }
    func clearPresetSession() { activePreset = nil; presetBase = nil }

    // MARK: Point colour (eyedropper)

    /// Samples the preview at a normalised point (top-left origin) and adds a point colour.
    func pickColor(at p: CGPoint) {
        pickingColor = false
        guard let cg = preview?.cgImage else { return }
        let x = min(max(Int(p.x * CGFloat(cg.width)), 0), cg.width - 1)
        let y = min(max(Int(p.y * CGFloat(cg.height)), 0), cg.height - 1)
        // average a 5×5 area
        guard let crop = cg.cropping(to: CGRect(x: max(0, x - 2), y: max(0, y - 2), width: 5, height: 5)),
              let px = AIModels.rgbaBytes(crop, width: 1, height: 1) else { return }
        let pc = PointColor(r: Double(px[0]) / 255, g: Double(px[1]) / 255, b: Double(px[2]) / 255)
        edit { $0.pointColors.append(pc) }
        selectedPointID = pc.id
    }
    func updatePoint(_ change: (inout PointColor) -> Void) {
        guard let i = settings.pointColors.firstIndex(where: { $0.id == selectedPointID }) else { return }
        change(&settings.pointColors[i])
    }

    // MARK: Healing

    var selectedHeal: HealSpot? { settings.healSpots.first { $0.id == selectedHealID } }
    func updateHeal(_ change: (inout HealSpot) -> Void) {
        guard let i = settings.healSpots.firstIndex(where: { $0.id == selectedHealID }) else { return }
        change(&settings.healSpots[i])
    }

    /// Adds a heal spot at a normalised point; the best source patch nearby is chosen automatically.
    func addHeal(at p: CGPoint) {
        var spot = HealSpot(x: Double(p.x), y: Double(p.y), srcX: Double(p.x) + healSize * 2.5, srcY: Double(p.y), radius: healSize, clone: healClone)
        if let cg = preview?.cgImage { autoSource(&spot, cg) }
        edit { $0.healSpots.append(spot) }
        selectedHealID = spot.id
    }

    /// Recomputes the colour match after moving the source.
    func refreshHealShift() {
        guard var sp = selectedHeal, let cg = preview?.cgImage else { return }
        sp.shift = colorShift(sp, cg)
        let fixed = sp
        updateHeal { $0 = fixed }
    }

    private func samples(_ cg: CGImage) -> (bytes: [UInt8], w: Int, h: Int)? {
        let k = min(1, 512 / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * k)), h = max(1, Int(CGFloat(cg.height) * k))
        guard let b = AIModels.rgbaBytes(cg, width: w, height: h) else { return nil }
        return (b, w, h)
    }

    private func ring(_ s: (bytes: [UInt8], w: Int, h: Int), cx: Double, cy: Double, r: Double) -> [[Double]] {
        var out: [[Double]] = []
        for k in 0..<24 {
            let a = Double(k) / 24 * 2 * .pi
            let x = Int(cx + cos(a) * r), y = Int(cy + sin(a) * r)
            guard x >= 0, y >= 0, x < s.w, y < s.h else { out.append([-1, -1, -1]); continue }
            let i = (y * s.w + x) * 4
            out.append([Double(s.bytes[i]) / 255, Double(s.bytes[i + 1]) / 255, Double(s.bytes[i + 2]) / 255])
        }
        return out
    }

    private func autoSource(_ spot: inout HealSpot, _ cg: CGImage) {
        guard let s = samples(cg) else { return }
        let short = Double(min(s.w, s.h))
        let cx = spot.x * Double(s.w), cy = spot.y * Double(s.h), r = spot.radius * short
        let dstRing = ring(s, cx: cx, cy: cy, r: r * 1.15)
        var best: (Double, Double, Double)? = nil   // (cost, x, y)
        for dist in [2.3, 3.2, 4.5] {
            for k in 0..<16 {
                let a = Double(k) / 16 * 2 * .pi
                let sx = cx + cos(a) * r * dist, sy = cy + sin(a) * r * dist
                guard sx - r > 0, sy - r > 0, sx + r < Double(s.w), sy + r < Double(s.h) else { continue }
                let srcRing = ring(s, cx: sx, cy: sy, r: r * 1.15)
                var cost = 0.0
                for (p, q) in zip(dstRing, srcRing) where p[0] >= 0 && q[0] >= 0 {
                    cost += pow(p[0] - q[0], 2) + pow(p[1] - q[1], 2) + pow(p[2] - q[2], 2)
                }
                cost *= 1 + dist * 0.05
                if best == nil || cost < best!.0 { best = (cost, sx, sy) }
            }
        }
        if let best { spot.srcX = best.1 / Double(s.w); spot.srcY = best.2 / Double(s.h) }
        spot.shift = colorShift(spot, cg)
    }

    private func colorShift(_ spot: HealSpot, _ cg: CGImage) -> [Double] {
        guard !spot.clone, let s = samples(cg) else { return [0, 0, 0] }
        let short = Double(min(s.w, s.h))
        let r = spot.radius * short * 1.15
        func mean(_ ring: [[Double]]) -> [Double] {
            let v = ring.filter { $0[0] >= 0 }
            guard !v.isEmpty else { return [0, 0, 0] }
            return (0..<3).map { c in v.map { pow($0[c], 2.2) }.reduce(0, +) / Double(v.count) }
        }
        let d = mean(ring(s, cx: spot.x * Double(s.w), cy: spot.y * Double(s.h), r: r))
        let src = mean(ring(s, cx: spot.srcX * Double(s.w), cy: spot.srcY * Double(s.h), r: r))
        return (0..<3).map { d[$0] - src[$0] }
    }

    // MARK: Select Object

    func addObjectMask(rect: NormRect) {
        drawingObject = false
        guard let source else { return }
        var layer = MaskLayer(kind: .object)
        layer.objectRect = rect
        maskBusy = "Finding the object…"
        let dir = itemDir, id = layer.id
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MaskEngine.shared.generateObject(rect: rect, layerID: id, source: source, itemDir: dir)
                DispatchQueue.main.async {
                    self.maskBusy = nil
                    self.edit { $0.masks.append(layer) }
                    self.selectedMaskID = id
                }
            } catch {
                DispatchQueue.main.async { self.maskBusy = nil; self.maskError = error.localizedDescription }
            }
        }
    }

    // MARK: Versions

    func saveVersion(named name: String) {
        versions.append(LibraryStore.Version(name: name.isEmpty ? "Version \(versions.count + 1)" : name, settings: settings))
        LibraryStore.shared.saveVersions(versions, for: item)
    }
    func applyVersion(_ v: LibraryStore.Version) { settings = v.settings; commit() }
    func deleteVersion(_ v: LibraryStore.Version) {
        versions.removeAll { $0.id == v.id }
        LibraryStore.shared.saveVersions(versions, for: item)
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

    @Published var exportProgress: Double?

    func export(format: RenderPipeline.ExportFormat, quality: Double, maxLongEdge: CGFloat?, layout: ExportLayout = ExportLayout(),
                upscale: Int = 1, completion: @escaping (URL?) -> Void) {
        guard let source else { completion(nil); return }
        let s = settings, name = (item.name as NSString).deletingPathExtension
        let bg = UIApplication.shared.beginBackgroundTask(withName: "export")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { UIApplication.shared.endBackgroundTask(bg) }
            let pipeline = RenderPipeline.shared
            guard var img = pipeline.renderFull(source: source, settings: s) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            if upscale > 1 {
                if let up = try? Upscaler.upscale(img, factor: upscale, progress: { p in DispatchQueue.main.async { self.exportProgress = p } }) {
                    img = up
                }
                DispatchQueue.main.async { self.exportProgress = nil }
            }
            img = layout.apply(img)
            guard
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
