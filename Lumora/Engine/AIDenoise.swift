import CoreImage
import CoreML
import UIKit

/// Neural denoising (DRUNet) of the full-resolution photo, processed in 512×512 tiles on the Neural Engine.
/// The result is saved next to the original as denoised.heic and used as the editing base.
enum AIDenoise {
    static let tile = 512
    static let overlap = 32

    static func outputURL(_ itemDir: URL) -> URL { itemDir.appendingPathComponent("denoised.heic") }
    static func infoURL(_ itemDir: URL) -> URL { itemDir.appendingPathComponent("denoised.json") }

    static func appliedAmount(_ itemDir: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: outputURL(itemDir).path),
              let d = try? Data(contentsOf: infoURL(itemDir)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Double] else { return nil }
        return j["amount"]
    }

    static func remove(_ itemDir: URL) {
        try? FileManager.default.removeItem(at: outputURL(itemDir))
        try? FileManager.default.removeItem(at: infoURL(itemDir))
    }

    /// Model noise level for the Amount slider (0...100).
    static func sigma(_ amount: Double) -> Float {
        Float(pow(max(amount, 0) / 100, 1.25) * 32 / 255)
    }

    /// The photo before denoising, gamma-encoded, full resolution.
    private static func noisyImage(source: PhotoSource, settings: EditSettings) -> CIImage? {
        var s = settings
        s.aiDenoise = false
        s.noiseReduction = 0
        s.colorNoiseReduction = 0
        if source.isRAW { s.whiteBalance = "As Shot" }
        return source.makeBase(settings: s, maxDimension: nil, allowDenoised: false)?
            .applyingFilter("CILinearToSRGBToneCurve")
    }

    enum DenoiseError: LocalizedError {
        case model, image, encode
        var errorDescription: String? {
            switch self {
            case .model: return "The AI Denoise model isn't available."
            case .image: return "Couldn't read the photo."
            case .encode: return "Couldn't save the denoised photo."
            }
        }
    }

    /// Runs the model on one tile. `src` is RGBA Float16, row-major, full image.
    private static func runTile(model: MLModel, src: UnsafePointer<Float16>, dst: UnsafeMutablePointer<Float16>,
                                W: Int, H: Int, ox: Int, oy: Int, writeRect: (x0: Int, y0: Int, x1: Int, y1: Int),
                                sigma: MLMultiArray, input: MLMultiArray) throws {
        let T = tile, plane = T * T
        let p = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        for y in 0..<T {
            let sy = min(max(oy + y, 0), H - 1)
            for x in 0..<T {
                let sx = min(max(ox + x, 0), W - 1)
                let si = (sy * W + sx) * 4
                let di = y * T + x
                p[di] = Float(src[si])
                p[plane + di] = Float(src[si + 1])
                p[2 * plane + di] = Float(src[si + 2])
            }
        }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: input), "sigma": MLFeatureValue(multiArray: sigma)]))
        guard let res = out.featureValue(for: "output")?.multiArrayValue else { throw DenoiseError.model }
        let st = res.strides.map(\.intValue)  // [1,3,T,T]
        let cS = st[1], yS = st[2], xS = st[3]
        func read(_ c: Int, _ y: Int, _ x: Int) -> Float16 {
            let i = c * cS + y * yS + x * xS
            switch res.dataType {
            case .float16: return res.dataPointer.bindMemory(to: Float16.self, capacity: res.count)[i]
            default: return Float16(res.dataPointer.bindMemory(to: Float.self, capacity: res.count)[i])
            }
        }
        for y in writeRect.y0..<writeRect.y1 {
            for x in writeRect.x0..<writeRect.x1 {
                let lx = x - ox, ly = y - oy
                let di = (y * W + x) * 4
                dst[di] = read(0, ly, lx)
                dst[di + 1] = read(1, ly, lx)
                dst[di + 2] = read(2, ly, lx)
                dst[di + 3] = 1
            }
        }
    }

    /// Denoises a gamma-encoded image. progress is called on a background thread.
    private static func denoise(_ img: CIImage, amount: Double, progress: (Double) -> Void) throws -> CIImage {
        guard let model = AIModels.denoiser else { throw DenoiseError.model }
        let ctx = RenderPipeline.shared.context
        let E = img.extent
        let W = Int(E.width), H = Int(E.height)
        var src = [Float16](repeating: 0, count: W * H * 4)
        var dst = [Float16](repeating: 0, count: W * H * 4)
        src.withUnsafeMutableBytes { raw in
            ctx.render(img, toBitmap: raw.baseAddress!, rowBytes: W * 8, bounds: E, format: .RGBAh, colorSpace: nil)
        }
        let sig = try MLMultiArray(shape: [1], dataType: .float32)
        sig[0] = NSNumber(value: sigma(amount))
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float32)
        let step = tile - 2 * overlap
        let cols = Int(ceil(Double(W) / Double(step))), rows = Int(ceil(Double(H) / Double(step)))
        var done = 0
        try src.withUnsafeBufferPointer { s in
            try dst.withUnsafeMutableBufferPointer { d in
                for r in 0..<rows {
                    for c in 0..<cols {
                        try autoreleasepool {
                            let x0 = c * step, y0 = r * step
                            let wr = (x0, y0, min(x0 + step, W), min(y0 + step, H))
                            try runTile(model: model, src: s.baseAddress!, dst: d.baseAddress!, W: W, H: H,
                                        ox: x0 - overlap, oy: y0 - overlap, writeRect: wr, sigma: sig, input: input)
                        }
                        done += 1
                        progress(Double(done) / Double(rows * cols))
                    }
                }
            }
        }
        let data = dst.withUnsafeBufferPointer { Data(buffer: $0) }
        // values are gamma-encoded sRGB; tag them as sRGB so Core Image linearises correctly
        return CIImage(bitmapData: data, bytesPerRow: W * 8, size: E.size, format: .RGBAh,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Full run: denoise and save. Call from a background queue.
    static func run(source: PhotoSource, settings: EditSettings, itemDir: URL, amount: Double, progress: @escaping (Double) -> Void) throws {
        guard let img = noisyImage(source: source, settings: settings) else { throw DenoiseError.image }
        let out = try denoise(img, amount: amount, progress: progress)
        let ctx = RenderPipeline.shared.context
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        var data: Data?
        if let d = try? ctx.heif10Representation(of: out, colorSpace: cs, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]) {
            data = d
        } else {
            data = ctx.tiffRepresentation(of: out, format: .RGBA16, colorSpace: cs, options: [:])
        }
        guard let data else { throw DenoiseError.encode }
        try data.write(to: outputURL(itemDir), options: .atomic)
        let info = try JSONSerialization.data(withJSONObject: ["amount": amount])
        try info.write(to: infoURL(itemDir), options: .atomic)
    }

    /// Before/after preview of a 512×512 crop at 100% from the centre (or a chosen point, normalised).
    static func preview(source: PhotoSource, settings: EditSettings, amount: Double, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> (UIImage, UIImage)? {
        guard let img = noisyImage(source: source, settings: settings) else { return nil }
        let E = img.extent
        let size = CGFloat(tile)
        let r = CGRect(x: min(max(0, E.width * center.x - size / 2), max(0, E.width - size)),
                       y: min(max(0, E.height * (1 - center.y) - size / 2), max(0, E.height - size)),
                       width: min(size, E.width), height: min(size, E.height)).integral
        let crop = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        guard let after = try? denoise(crop, amount: amount, progress: { _ in }) else { return nil }
        let ctx = RenderPipeline.shared.context
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // `crop` holds gamma values in the working space: undo the tone curve so it displays like `after`
        let beforeDisplay = crop.applyingFilter("CISRGBToneCurveToLinear")
        guard let b = ctx.createCGImage(beforeDisplay, from: beforeDisplay.extent, format: .RGBA8, colorSpace: srgb),
              let a = ctx.createCGImage(after, from: after.extent, format: .RGBA8, colorSpace: srgb) else { return nil }
        return (UIImage(cgImage: b), UIImage(cgImage: a))
    }
}
