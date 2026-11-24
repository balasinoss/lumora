import Foundation
import CoreImage
import CoreML
import Vision
import UIKit

/// A smart album. Sharpness/focus albums use measurements; the rest use MobileCLIP image understanding.
struct SmartCategory: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var icon: String
    var prompts: [String]          // empty for measurement-based albums
    var builtIn: Bool = true
    var enabled: Bool = true
    var isMetric: Bool { prompts.isEmpty }
}

final class SmartSort: ObservableObject {
    static let shared = SmartSort()

    @Published var categories: [SmartCategory] { didSet { saveCategories() } }
    @Published private(set) var queued = 0
    @Published private(set) var done = 0
    @Published var autoAnalyze: Bool { didSet { UserDefaults.standard.set(autoAnalyze, forKey: "ss.auto") } }
    @Published var focusThreshold: Double { didSet { UserDefaults.standard.set(focusThreshold, forKey: "ss.focus") } }
    @Published var sharpThreshold: Double { didSet { UserDefaults.standard.set(sharpThreshold, forKey: "ss.sharp") } }
    @Published var blurThreshold: Double { didSet { UserDefaults.standard.set(blurThreshold, forKey: "ss.blur") } }
    /// 0...1, how confident the AI must be before adding a photo to an album
    @Published var strictness: Double { didSet { UserDefaults.standard.set(strictness, forKey: "ss.strict") } }

    private let queue = DispatchQueue(label: "lumora.smartsort", qos: .utility)
    private var textEmbeddings: [String: [Float]] = [:]
    private let embedLock = NSLock()

    static let defaults: [SmartCategory] = [
        SmartCategory(id: "focus", name: "In Focus", icon: "scope", prompts: []),
        SmartCategory(id: "sharp", name: "Sharpest", icon: "sparkle.magnifyingglass", prompts: []),
        SmartCategory(id: "blurry", name: "Blurry", icon: "aqi.medium", prompts: []),
        SmartCategory(id: "dunk", name: "Dunks", icon: "figure.basketball", prompts: [
            "a basketball player dunking the ball into the hoop", "a slam dunk at the rim", "a player hanging on the basketball rim"]),
        SmartCategory(id: "shot", name: "Shots & Layups", icon: "basketball", prompts: [
            "a basketball player shooting a jump shot", "a basketball player going up for a layup", "a player shooting a free throw"]),
        SmartCategory(id: "dribble", name: "Dribbling", icon: "figure.run", prompts: [
            "a basketball player dribbling the ball", "a point guard bringing the ball up the court"]),
        SmartCategory(id: "defense", name: "Defense & Blocks", icon: "hand.raised", prompts: [
            "a basketball player blocking a shot", "tight defense in a basketball game", "players fighting for a rebound"]),
        SmartCategory(id: "celebration", name: "Celebrations", icon: "party.popper", prompts: [
            "basketball players celebrating", "an athlete screaming and celebrating with joy", "teammates hugging and high fiving"]),
        SmartCategory(id: "fans", name: "Fans & Crowd", icon: "person.3", prompts: [
            "fans cheering in the stands", "the crowd at a basketball game", "spectators reacting in the arena"]),
        SmartCategory(id: "bench", name: "Bench & Coaches", icon: "person.wave.2", prompts: [
            "a basketball coach giving instructions on the sideline", "basketball players sitting on the bench", "a team huddle during a timeout"]),
        SmartCategory(id: "details", name: "Details & Close-ups", icon: "viewfinder", prompts: [
            "a close-up detail photo", "a macro detail shot of an object", "close-up of a basketball"]),
        SmartCategory(id: "hands", name: "Hands", icon: "hand.raised.fingers.spread", prompts: [
            "a close-up of a person's hands", "close-up of hands holding a basketball", "hands with tape and wristbands"]),
        SmartCategory(id: "tattoos", name: "Tattoos", icon: "scribble.variable", prompts: [
            "a close-up of a tattoo on skin", "a tattooed arm", "tattoos on a basketball player"]),
        SmartCategory(id: "shoes", name: "Shoes", icon: "shoe", prompts: [
            "close-up of basketball sneakers on the court", "a player's shoes", "sneakers on a wooden floor"]),
        SmartCategory(id: "tight", name: "Tight Shots", icon: "person.crop.rectangle", prompts: [
            "a tight close-up portrait of a basketball player's face", "a headshot of an athlete with an intense expression"]),
        SmartCategory(id: "wide", name: "Wide Shots", icon: "rectangle.expand.vertical", prompts: [
            "a wide shot of a basketball court with many players", "an overview of a full basketball arena"]),
    ]
    private static let neutralPrompts = ["a photo", "a photo of people", "a sports photo", "an indoor photo"]

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "ss.categories"), let c = try? JSONDecoder().decode([SmartCategory].self, from: data) {
            // add new built-ins that didn't exist when the user saved
            var cats = c
            for def in SmartSort.defaults where !cats.contains(where: { $0.id == def.id }) { cats.append(def) }
            categories = cats
        } else {
            categories = SmartSort.defaults
        }
        autoAnalyze = d.object(forKey: "ss.auto") as? Bool ?? true
        focusThreshold = d.object(forKey: "ss.focus") as? Double ?? 45
        sharpThreshold = d.object(forKey: "ss.sharp") as? Double ?? 62
        blurThreshold = d.object(forKey: "ss.blur") as? Double ?? 30
        strictness = d.object(forKey: "ss.strict") as? Double ?? 0.5
    }

    private func saveCategories() {
        if let data = try? JSONEncoder().encode(categories) { UserDefaults.standard.set(data, forKey: "ss.categories") }
    }

    var isBusy: Bool { queued > done }

    // MARK: Album membership (computed live, so changing thresholds re-sorts instantly)

    func albums(for item: PhotoItem) -> Set<String> {
        var set = Set(item.manualAlbums ?? [])
        guard let a = item.analysis else { return set }
        let enabled = Dictionary(uniqueKeysWithValues: categories.filter(\.enabled).map { ($0.id, $0) })
        if enabled["focus"] != nil && a.sharpness >= focusThreshold { set.insert("focus") }
        if enabled["sharp"] != nil && a.sharpness >= sharpThreshold { set.insert("sharp") }
        if enabled["blurry"] != nil && a.sharpness < blurThreshold { set.insert("blurry") }
        // AI categories: probability threshold scales with strictness
        let minP = 0.12 + strictness * 0.2
        for (id, p) in a.clipScores where enabled[id] != nil && p >= minP { set.insert(id) }
        // the single best category always counts if it is reasonably confident
        if let best = a.clipScores.filter({ enabled[$0.key] != nil }).max(by: { $0.value < $1.value }), best.value >= minP * 0.7 {
            set.insert(best.key)
        }
        // Vision-based boosts
        if enabled["tight"] != nil && a.largestFace >= 0.22 { set.insert("tight") }
        if enabled["fans"] != nil && a.people >= 8 && (a.clipScores["fans"] ?? 0) >= minP * 0.5 { set.insert("fans") }
        if enabled["celebration"] != nil && a.armsUp && (a.clipScores["celebration"] ?? 0) >= minP * 0.5 { set.insert("celebration") }
        if set.contains("hands") || set.contains("tattoos") || set.contains("shoes") { if enabled["details"] != nil { set.insert("details") } }
        for n in a.jerseys ?? [] { set.insert("jersey-\(n)") }
        return set
    }

    // MARK: Queue

    func enqueue(_ items: [PhotoItem], force: Bool = false) {
        let todo = items.filter { force || $0.analysis == nil }
        guard !todo.isEmpty else { return }
        DispatchQueue.main.async { self.queued += todo.count }
        for item in todo {
            queue.async { [weak self] in
                guard let self else { return }
                let result = autoreleasepool { self.analyze(item) }
                DispatchQueue.main.async {
                    self.done += 1
                    if let result, var current = LibraryStore.shared.items.first(where: { $0.id == item.id }) {
                        current.analysis = result
                        if current.captured == nil { current.captured = LibraryStore.captureDate(LibraryStore.shared.originalURL(current)) }
                        LibraryStore.shared.update(current, backup: false)
                    }
                    if self.done >= self.queued { self.done = 0; self.queued = 0 }
                }
            }
        }
    }

    /// Re-scores AI albums from stored image embeddings (after categories change). Fast.
    func rescoreAll() {
        let items = LibraryStore.shared.items
        queue.async { [weak self] in
            guard let self else { return }
            self.embedLock.lock(); self.textEmbeddings = [:]; self.embedLock.unlock()
            var updates: [PhotoItem] = []
            for var item in items {
                guard var a = item.analysis, let emb = self.loadImageEmbedding(item) else { continue }
                a.clipScores = self.scores(for: emb)
                item.analysis = a
                updates.append(item)
            }
            DispatchQueue.main.async { for u in updates { LibraryStore.shared.update(u, backup: false) } }
        }
    }

    // MARK: Analysis

    private func embeddingURL(_ item: PhotoItem) -> URL { LibraryStore.shared.dir(item).appendingPathComponent("clip.bin") }
    private func loadImageEmbedding(_ item: PhotoItem) -> [Float]? {
        guard let d = try? Data(contentsOf: embeddingURL(item)), d.count >= 4 else { return nil }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func analyze(_ item: PhotoItem) -> PhotoAnalysis? {
        let url = LibraryStore.shared.originalURL(item)
        guard let src = PhotoSource(url: url), let cg = src.quickImage(maxPixel: 1536) else { return nil }
        var a = PhotoAnalysis()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let pose = VNDetectHumanBodyPoseRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.minimumTextHeight = 0.025
        try? handler.perform([faces, humans, pose, saliency, quality, text])
        a.faceQuality = (quality.results ?? []).compactMap { $0.faceCaptureQuality.map(Double.init) }.max()
        // jersey numbers: 1–2 digit numbers read with good confidence
        var nums = Set<Int>()
        for obs in text.results ?? [] {
            guard let cand = obs.topCandidates(1).first, cand.confidence >= 0.5 else { continue }
            let t = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count <= 2, let n = Int(t), obs.boundingBox.height > 0.03 { nums.insert(n) }
        }
        a.jerseys = Array(nums).sorted()

        let faceObs = faces.results ?? []
        a.faces = faceObs.count
        a.largestFace = Double(faceObs.map { $0.boundingBox.height }.max() ?? 0)
        let humanObs = (humans.results ?? []).filter { $0.confidence > 0.4 }
        a.people = max(humanObs.count, a.faces)
        a.armsUp = (pose.results ?? []).contains { p in
            guard let pts = try? p.recognizedPoints(.all) else { return false }
            func y(_ j: VNHumanBodyPoseObservation.JointName) -> CGFloat? {
                guard let q = pts[j], q.confidence > 0.3 else { return nil }; return q.location.y
            }
            guard let nose = y(.nose) ?? y(.neck) else { return false }
            let wrists = [y(.leftWrist), y(.rightWrist)].compactMap { $0 }
            return wrists.contains { $0 > nose + 0.02 }
        }

        // Subject region: biggest person, otherwise the most salient area
        var subject = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        if let big = humanObs.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            subject = big.boundingBox
        } else if let sal = (saliency.results?.first?.salientObjects ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            subject = sal.boundingBox
        }
        let (subj, whole) = sharpness(cg, subject: subject)
        a.sharpness = subj
        a.backgroundSharpness = whole

        if let emb = imageEmbedding(cg) {
            try? emb.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: embeddingURL(item), options: .atomic)
            a.clipScores = scores(for: emb)
        }
        return a
    }

    /// Variance of the Laplacian inside the subject (and over the whole frame), mapped to 0...100.
    private func sharpness(_ cg: CGImage, subject: CGRect) -> (Double, Double) {
        let ctx = RenderPipeline.shared.context
        let img = CIImage(cgImage: cg)
        let E = img.extent
        let gray = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CILinearToSRGBToneCurve")
            .lumoraBlur(0.6)
        let lap = gray.applyingFilter("CIConvolution3X3", parameters: [
            "inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), "inputBias": 0]).cropped(to: E)
        let sq = lap.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: lap])
        func mean(_ r: CGRect) -> Double {
            let avg = sq.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            var px = [Float](repeating: 0, count: 4)
            ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return Double(px[0])
        }
        let r = CGRect(x: E.minX + subject.minX * E.width, y: E.minY + subject.minY * E.height,
                       width: subject.width * E.width, height: subject.height * E.height).intersection(E.insetBy(dx: 2, dy: 2))
        func score(_ v: Double) -> Double {
            let x = log10(max(v * 65025, 1))   // variance in 0-255 units
            return min(100, max(0, (x - 1.0) / 2.0 * 100))
        }
        let whole = score(mean(E.insetBy(dx: 2, dy: 2)))
        let subj = r.isEmpty ? whole : score(mean(r))
        return (subj, whole)
    }

    // MARK: CLIP

    private func imageEmbedding(_ cg: CGImage) -> [Float]? {
        guard let model = AIModels.clipImage,
              let (name, desc) = model.modelDescription.inputDescriptionsByName.first else { return nil }
        let square = AIModels.centerSquare(cg)
        var value: MLFeatureValue?
        if desc.type == .image, let c = desc.imageConstraint {
            if let pb = AIModels.pixelBuffer(from: square, width: c.pixelsWide, height: c.pixelsHigh, format: c.pixelFormatType == kCVPixelFormatType_32BGRA ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_32BGRA) {
                value = MLFeatureValue(pixelBuffer: pb)
            }
        } else if let c = desc.multiArrayConstraint {
            let shape = c.shape.map(\.intValue)
            let h = shape.count >= 2 ? shape[shape.count - 2] : 256, w = shape.last ?? 256
            if let arr = AIModels.planarArray(from: square, width: w, height: h) { value = MLFeatureValue(multiArray: arr) }
        }
        guard let value, let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: value])) else { return nil }
        return firstEmbedding(out, model: model)
    }

    private func firstEmbedding(_ out: MLFeatureProvider, model: MLModel) -> [Float]? {
        let names = model.modelDescription.outputDescriptionsByName.keys.sorted { a, b in
            (a.contains("emb") ? 0 : 1) < (b.contains("emb") ? 0 : 1)
        }
        for n in names {
            if let arr = out.featureValue(for: n)?.multiArrayValue {
                return normalize(AIModels.floats(arr))
            }
        }
        return nil
    }

    private func normalize(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    func textEmbedding(_ text: String) -> [Float]? {
        guard let model = AIModels.clipText, ClipTokenizer.shared.ready,
              let (name, desc) = model.modelDescription.inputDescriptionsByName.first,
              let c = desc.multiArrayConstraint else { return nil }
        let len = c.shape.last?.intValue ?? 77
        let ids = ClipTokenizer.shared.encode(text, length: len)
        guard let arr = try? MLMultiArray(shape: c.shape, dataType: c.dataType == .int32 ? .int32 : .float32) else { return nil }
        for (i, t) in ids.enumerated() { arr[i] = NSNumber(value: t) }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: arr)])) else { return nil }
        return firstEmbedding(out, model: model)
    }

    private func categoryEmbedding(_ cat: SmartCategory) -> [Float]? {
        let key = cat.id + "|" + cat.prompts.joined(separator: "|")
        embedLock.lock()
        if let e = textEmbeddings[key] { embedLock.unlock(); return e }
        embedLock.unlock()
        let embs = cat.prompts.compactMap { textEmbedding($0) }
        guard let first = embs.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for e in embs { for i in 0..<sum.count { sum[i] += e[i] } }
        let e = normalize(sum)
        embedLock.lock(); textEmbeddings[key] = e; embedLock.unlock()
        return e
    }

    private lazy var neutralEmbeddings: [[Float]] = SmartSort.neutralPrompts.compactMap { textEmbedding($0) }

    /// Probability per AI category (softmax over categories + neutral prompts).
    private func scores(for img: [Float]) -> [String: Double] {
        let cats = categories.filter { !$0.isMetric }
        var logits: [(String?, Float)] = []
        for c in cats {
            guard let e = categoryEmbedding(c), e.count == img.count else { continue }
            logits.append((c.id, zip(e, img).reduce(0) { $0 + $1.0 * $1.1 } * 100))
        }
        for e in neutralEmbeddings where e.count == img.count {
            logits.append((nil, zip(e, img).reduce(0) { $0 + $1.0 * $1.1 } * 100))
        }
        guard let m = logits.map(\.1).max() else { return [:] }
        let exps = logits.map { exp(Double($0.1 - m)) }
        let total = exps.reduce(0, +)
        var out: [String: Double] = [:]
        for (i, l) in logits.enumerated() { if let id = l.0 { out[id] = exps[i] / total } }
        return out
    }
}
