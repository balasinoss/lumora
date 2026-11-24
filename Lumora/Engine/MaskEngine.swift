import CoreImage
import CoreML
import Vision
import UIKit

/// Creates AI masks (Vision + sky model), turns mask layers into images and applies local adjustments.
final class MaskEngine {
    static let shared = MaskEngine()
    private let ctx = RenderPipeline.shared.context
    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()

    enum MaskError: LocalizedError {
        case noImage, notFound(String), model
        var errorDescription: String? {
            switch self {
            case .noImage: return "Couldn't read the photo."
            case .notFound(let s): return "No \(s) found in this photo."
            case .model: return "The AI model isn't available."
            }
        }
    }

    // MARK: Files

    func masksDir(_ itemDir: URL) -> URL {
        let d = itemDir.appendingPathComponent("masks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func fileName(kind: MaskKind, personIndex: Int) -> String? {
        switch kind {
        case .subject, .background: return "subject.png"
        case .sky: return "sky.png"
        case .people: return "people.png"
        case .person: return "person\(personIndex).png"
        default: return nil
        }
    }
    func maskURL(_ itemDir: URL, kind: MaskKind, personIndex: Int) -> URL? {
        fileName(kind: kind, personIndex: personIndex).map { masksDir(itemDir).appendingPathComponent($0) }
    }
    func hasMask(_ itemDir: URL, kind: MaskKind, personIndex: Int = 0) -> Bool {
        guard let u = maskURL(itemDir, kind: kind, personIndex: personIndex) else { return true }
        return FileManager.default.fileExists(atPath: u.path)
    }

    // MARK: Generation (runs off the main thread)

    /// Image the AI sees: the photo with default settings, as an 8-bit sRGB CGImage (oriented, ~2048px).
    private func analysisImage(source: PhotoSource) -> CGImage? {
        guard let base = source.previewBase(settings: .defaults(isRAW: source.isRAW), context: ctx) else { return nil }
        let g = base.applyingFilter("CILinearToSRGBToneCurve")
        return ctx.createCGImage(g, from: g.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Number of separate people Vision can find (for "Person 1…4" masks).
    func detectPeople(source: PhotoSource, itemDir: URL) -> Int {
        let countURL = masksDir(itemDir).appendingPathComponent("people-count.txt")
        if let s = try? String(contentsOf: countURL, encoding: .utf8), let n = Int(s) { return n }
        guard let cg = analysisImage(source: source) else { return 0 }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let req = VNGeneratePersonInstanceMaskRequest()
        try? handler.perform([req])
        let n = req.results?.first?.allInstances.count ?? 0
        try? String(n).write(to: countURL, atomically: true, encoding: .utf8)
        return n
    }

    func generate(kind: MaskKind, personIndex: Int = 0, source: PhotoSource, itemDir: URL) throws {
        guard let url = maskURL(itemDir, kind: kind, personIndex: personIndex) else { return }
        if FileManager.default.fileExists(atPath: url.path) { return }
        guard let cg = analysisImage(source: source) else { throw MaskError.noImage }
        let size = CGSize(width: cg.width, height: cg.height)
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        var mask: CIImage

        switch kind {
        case .subject, .background:
            let req = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([req])
            guard let obs = req.results?.first, !obs.allInstances.isEmpty else { throw MaskError.notFound("subject") }
            let pb = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
            mask = CIImage(cvPixelBuffer: pb)
        case .people:
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .accurate
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([req])
            guard let pb = req.results?.first?.pixelBuffer else { throw MaskError.notFound("people") }
            mask = CIImage(cvPixelBuffer: pb)
        case .person:
            let req = VNGeneratePersonInstanceMaskRequest()
            try handler.perform([req])
            guard let obs = req.results?.first else { throw MaskError.notFound("people") }
            let inst = Array(obs.allInstances).sorted()
            guard personIndex < inst.count else { throw MaskError.notFound("person \(personIndex + 1)") }
            let pb = try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: inst[personIndex]), from: handler)
            mask = CIImage(cvPixelBuffer: pb)
        case .sky:
            mask = try skyMask(cg)
        default:
            return
        }
        // scale to the analysis image size
        let sx = size.width / mask.extent.width, sy = size.height / mask.extent.height
        mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        mask = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .cropped(to: CGRect(origin: .zero, size: size))
        guard let png = ctx.pngRepresentation(of: mask, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray(), options: [:]) else { throw MaskError.noImage }
        try png.write(to: url, options: .atomic)
    }

    private func skyMask(_ cg: CGImage) throws -> CIImage {
        guard let model = AIModels.sky, let arr = AIModels.planarArray(from: cg, width: 512, height: 512) else { throw MaskError.model }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: arr)]))
        guard let name = model.modelDescription.outputDescriptionsByName.keys.first,
              let res = out.featureValue(for: name)?.multiArrayValue else { throw MaskError.model }
        let shape = res.shape.map(\.intValue)
        let h = shape[shape.count - 2], w = shape[shape.count - 1]
        var vals = AIModels.floats(res)
        if vals.max() ?? 0 < 0.05 { throw MaskError.notFound("sky") }
        let data = vals.withUnsafeMutableBufferPointer { Data(buffer: $0) }
        var m = CIImage(bitmapData: data, bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .Rf, colorSpace: nil)
        // upscale smoothly, then snap edges to the photo with a guided filter
        let guide = CIImage(cgImage: cg)
        m = m.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(cg.width) / CGFloat(w),
                                                                       kCIInputAspectRatioKey: (CGFloat(cg.height) / CGFloat(h)) / (CGFloat(cg.width) / CGFloat(w))])
            .cropped(to: guide.extent)
        if let f = CIFilter(name: "CIGuidedFilter") {
            f.setValue(m.clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(guide.clampedToExtent(), forKey: "inputGuideImage")
            f.setValue(Double(max(cg.width, cg.height)) * 0.006, forKey: "inputRadius")
            f.setValue(0.0004, forKey: "inputEpsilon")
            if let o = f.outputImage { m = o.cropped(to: guide.extent) }
        }
        // sharpen the probability into a cleaner mask
        m = m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1.6, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1.6, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: -0.3, y: -0.3, z: -0.3, w: 1)])
            .applyingFilter("CIColorClamp")
        return m
    }

    // MARK: Mask images

    private func loadPNG(_ url: URL) -> CIImage? {
        let key = url.path
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        guard let img = CIImage(contentsOf: url) else { return nil }
        cache[key] = img
        return img
    }
    func invalidate(_ itemDir: URL) {
        lock.lock(); cache = cache.filter { !$0.key.hasPrefix(itemDir.path) }; lock.unlock()
    }

    /// Mask for a layer as a CIImage covering `extent` (origin 0,0). Value in every channel, 0...1.
    func image(for layer: MaskLayer, itemDir: URL, extent E: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: E)
        var base = black
        var invert = layer.invert
        switch layer.kind {
        case .subject, .sky, .people, .person, .background:
            if let url = maskURL(itemDir, kind: layer.kind, personIndex: layer.personIndex), let m = loadPNG(url) {
                base = m.transformed(by: CGAffineTransform(scaleX: E.width / m.extent.width, y: E.height / m.extent.height)).cropped(to: E)
            }
            if layer.kind == .background { invert.toggle() }
        case .linear:
            if let g = layer.linear {
                base = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: CGFloat(g.start.x) * E.width, y: CGFloat(1 - g.start.y) * E.height),
                    "inputPoint1": CIVector(x: CGFloat(g.end.x) * E.width, y: CGFloat(1 - g.end.y) * E.height),
                    "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: E)
            }
        case .radial:
            if let g = layer.radial {
                let c = CGPoint(x: CGFloat(g.center.x) * E.width, y: CGFloat(1 - g.center.y) * E.height)
                let rx = max(2, CGFloat(g.radiusX) * E.width), ry = max(2, CGFloat(g.radiusY) * E.height)
                let inner = rx * CGFloat(1 - min(max(g.feather, 0), 1) * 0.95)
                let grad = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": inner, "inputRadius1": rx,
                    "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
                base = grad.transformed(by: CGAffineTransform(scaleX: 1, y: ry / rx).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
                    .cropped(to: E)
                if !g.inside { invert.toggle() }
            }
        case .brush:
            break
        }
        let (add, erase) = strokesImages(layer.strokes, extent: E)
        return Kernels.maskCombine.apply(extent: E, arguments: [base, add ?? black, erase ?? black,
                                                                  invert ? 1.0 : 0.0, layer.opacity / 100]) ?? base
    }

    /// Renders brush strokes into add / erase masks.
    private func strokesImages(_ strokes: [BrushStroke], extent E: CGRect) -> (CIImage?, CIImage?) {
        guard !strokes.isEmpty else { return (nil, nil) }
        let longEdge: CGFloat = 1024
        let k = longEdge / max(E.width, E.height)
        let w = max(1, Int(E.width * k)), h = max(1, Int(E.height * k))
        let short = CGFloat(min(w, h))
        func render(_ list: [BrushStroke]) -> CIImage? {
            guard !list.isEmpty,
                  let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.setLineCap(.round); c.setLineJoin(.round)
            var feather: CGFloat = 0
            for s in list {
                let width = CGFloat(s.size) * short
                feather = max(feather, CGFloat(s.feather) * width * 0.35)
                c.setStrokeColor(gray: 1, alpha: CGFloat(s.flow))
                c.setFillColor(gray: 1, alpha: CGFloat(s.flow))
                c.setLineWidth(width)
                let pts = s.points.map { CGPoint(x: CGFloat($0.x) * CGFloat(w), y: CGFloat(1 - $0.y) * CGFloat(h)) }
                if pts.count == 1 {
                    c.fillEllipse(in: CGRect(x: pts[0].x - width / 2, y: pts[0].y - width / 2, width: width, height: width))
                } else if let f = pts.first {
                    c.beginPath(); c.move(to: f)
                    for p in pts.dropFirst() { c.addLine(to: p) }
                    c.strokePath()
                }
            }
            guard let cg = c.makeImage() else { return nil }
            var img = CIImage(cgImage: cg)
            if feather > 0.5 { img = img.lumoraBlur(feather) }
            return img.transformed(by: CGAffineTransform(scaleX: E.width / CGFloat(w), y: E.height / CGFloat(h))).cropped(to: E)
        }
        return (render(strokes.filter { !$0.erase }), render(strokes.filter { $0.erase }))
    }

    // MARK: Local adjustments (input/output gamma-encoded)

    func applyLocal(_ img: CIImage, _ a: LocalAdjust, pixelScale px: CGFloat) -> CIImage {
        var out = img
        let E = img.extent
        let short = min(E.width, E.height)
        if a.exposure != 0 || a.temperature != 0 || a.tint != 0 {
            var lin = out.applyingFilter("CISRGBToneCurveToLinear")
            if a.exposure != 0 { lin = lin.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
            if a.temperature != 0 || a.tint != 0 {
                lin = lin.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: CGFloat(6500 * pow(2.0, a.temperature / 100)), y: CGFloat(a.tint)),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0)])
            }
            out = lin.applyingFilter("CILinearToSRGBToneCurve")
        }
        if a.contrast != 0 || a.highlights != 0 || a.shadows != 0 || a.whites != 0 || a.blacks != 0 {
            let local = out.lumoraBlur(short * 0.012)
            out = Kernels.tone.apply(extent: E, arguments: [out, local,
                CIVector(x: a.highlights / 100, y: a.shadows / 100, z: a.whites / 100, w: a.blacks / 100), a.contrast / 100]) ?? out
        }
        if a.dehaze != 0 {
            let dark = (Kernels.darkChannel.apply(extent: E, arguments: [out]) ?? out).lumoraBlur(short * 0.02)
            out = Kernels.dehaze.apply(extent: E, arguments: [out, dark, a.dehaze / 100]) ?? out
        }
        if a.clarity != 0 {
            out = Kernels.localContrast.apply(extent: E, arguments: [out, out.lumoraBlur(short * 0.018), a.clarity / 100 * 1.1, 1.0]) ?? out
        }
        if a.texture != 0 {
            out = Kernels.localContrast.apply(extent: E, arguments: [out, out.lumoraBlur(max(1, short * 0.0035)), a.texture / 100 * 1.6, 0.0]) ?? out
        }
        if a.saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + a.saturation / 100])
        }
        if a.sharpness > 0 {
            let b = out.lumoraBlur(max(0.5, px)), wide = out.lumoraBlur(max(1.5, 3 * px))
            out = Kernels.sharpen.apply(extent: E, arguments: [out, b, wide, a.sharpness / 100 * 1.8, 0.3, 0.0]) ?? out
        } else if a.sharpness < 0 {
            out = Kernels.localContrast.apply(extent: E, arguments: [out, out.lumoraBlur(max(1.5, short * 0.004)), a.sharpness / 100, 0.0]) ?? out
        }
        return out
    }
}
