import CoreImage
import CoreML
import UIKit

/// AI upscaling (Real-ESRGAN general x4v3) in 256-px tiles. Output is 2× or 4×.
enum AIUpscaler {
    static let tile = 256
    static let overlap = 12
    /// Largest output we allow (megapixels) so the iPhone doesn't run out of memory.
    static let maxOutputMP: Double = 40

    static func maxFactor(for size: CGSize) -> Int {
        let mp = Double(size.width * size.height) / 1_000_000
        if mp * 16 <= maxOutputMP { return 4 }
        if mp * 4 <= maxOutputMP { return 2 }
        return 1
    }

    enum UpscaleError: LocalizedError {
        case model, tooLarge
        var errorDescription: String? {
            switch self {
            case .model: return "The AI Upscale model isn't available."
            case .tooLarge: return "This photo is already too large to upscale on iPhone."
            }
        }
    }

    /// `img` is the finished, linear image. Returns a linear image `factor` times larger.
    static func upscale(_ img: CIImage, factor: Int, progress: (Double) -> Void) throws -> CIImage {
        guard let model = AIModels.upscaler else { throw UpscaleError.model }
        guard factor == 2 || factor == 4, maxFactor(for: img.extent.size) >= factor else { throw UpscaleError.tooLarge }
        let ctx = RenderPipeline.shared.context
        let gamma = img.applyingFilter("CILinearToSRGBToneCurve")
        let E = gamma.extent.integral
        let W = Int(E.width), H = Int(E.height)
        var src = [Float16](repeating: 0, count: W * H * 4)
        src.withUnsafeMutableBytes { raw in
            ctx.render(gamma, toBitmap: raw.baseAddress!, rowBytes: W * 8, bounds: E, format: .RGBAh, colorSpace: nil)
        }
        let OW = W * factor, OH = H * factor
        var dst = [UInt8](repeating: 255, count: OW * OH * 4)
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float32)
        let step = tile - 2 * overlap
        let cols = Int(ceil(Double(W) / Double(step))), rows = Int(ceil(Double(H) / Double(step)))
        let down = 4 / factor   // average 4x output down to the requested factor
        var done = 0
        try src.withUnsafeBufferPointer { s in
            try dst.withUnsafeMutableBufferPointer { d in
                for r in 0..<rows {
                    for c in 0..<cols {
                        try autoreleasepool {
                            let x0 = c * step, y0 = r * step
                            let ox = x0 - overlap, oy = y0 - overlap
                            let plane = tile * tile
                            let p = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
                            for y in 0..<tile {
                                let sy = min(max(oy + y, 0), H - 1)
                                for x in 0..<tile {
                                    let sx = min(max(ox + x, 0), W - 1)
                                    let si = (sy * W + sx) * 4, di = y * tile + x
                                    p[di] = Float(s[si]); p[plane + di] = Float(s[si + 1]); p[2 * plane + di] = Float(s[si + 2])
                                }
                            }
                            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]))
                            guard let res = out.featureValue(for: "output")?.multiArrayValue else { throw UpscaleError.model }
                            let st = res.strides.map(\.intValue)
                            let isHalf = res.dataType == .float16
                            let fp = res.dataPointer.bindMemory(to: Float.self, capacity: res.count)
                            let hp = res.dataPointer.bindMemory(to: Float16.self, capacity: res.count)
                            func val(_ ch: Int, _ y: Int, _ x: Int) -> Float {
                                let i = ch * st[1] + y * st[2] + x * st[3]
                                return isHalf ? Float(hp[i]) : fp[i]
                            }
                            // write the centre region (in output pixels at `factor`)
                            let wx0 = x0 * factor, wy0 = y0 * factor
                            let wx1 = min(x0 + step, W) * factor, wy1 = min(y0 + step, H) * factor
                            for oyy in wy0..<wy1 {
                                for oxx in wx0..<wx1 {
                                    // position inside the 4x tile
                                    let tx = (oxx - ox * factor) * down, ty = (oyy - oy * factor) * down
                                    var rgb: (Float, Float, Float) = (0, 0, 0)
                                    for dy in 0..<down { for dx in 0..<down {
                                        rgb.0 += val(0, ty + dy, tx + dx); rgb.1 += val(1, ty + dy, tx + dx); rgb.2 += val(2, ty + dy, tx + dx)
                                    } }
                                    let n = Float(down * down)
                                    let di = (oyy * OW + oxx) * 4
                                    d[di] = UInt8(max(0, min(255, rgb.0 / n * 255 + 0.5)))
                                    d[di + 1] = UInt8(max(0, min(255, rgb.1 / n * 255 + 0.5)))
                                    d[di + 2] = UInt8(max(0, min(255, rgb.2 / n * 255 + 0.5)))
                                }
                            }
                        }
                        done += 1
                        progress(Double(done) / Double(rows * cols))
                    }
                }
            }
        }
        let data = dst.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: OW * 4, size: CGSize(width: OW, height: OH), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// Social-media sizes, borders and watermark.
struct ExportLayout: Codable, Equatable {
    enum Frame: String, Codable, CaseIterable, Identifiable {
        case original = "Original", post45 = "Instagram 4:5", square = "Square 1:1", story = "Story 9:16", landscape = "Landscape 16:9"
        var id: String { rawValue }
        var size: CGSize? {
            switch self {
            case .original: return nil
            case .post45: return CGSize(width: 1080, height: 1350)
            case .square: return CGSize(width: 1080, height: 1080)
            case .story: return CGSize(width: 1080, height: 1920)
            case .landscape: return CGSize(width: 1920, height: 1080)
            }
        }
    }
    enum Fit: String, Codable, CaseIterable, Identifiable {
        case fill = "Crop to fill", blur = "Fit · blurred background", black = "Fit · black border", white = "Fit · white border"
        var id: String { rawValue }
    }
    enum Corner: String, Codable, CaseIterable, Identifiable {
        case bottomRight = "Bottom right", bottomLeft = "Bottom left", topRight = "Top right", topLeft = "Top left", center = "Center"
        var id: String { rawValue }
    }

    var frame: Frame = .original
    var fit: Fit = .blur
    var watermark = false
    var watermarkText = ""
    var useLogo = false
    var corner: Corner = .bottomRight
    var opacity: Double = 0.8
    var size: Double = 0.035          // text height as a fraction of the short side

    static var saved: ExportLayout {
        get {
            guard let d = UserDefaults.standard.data(forKey: "exportLayout"), let l = try? JSONDecoder().decode(ExportLayout.self, from: d) else { return ExportLayout() }
            return l
        }
        set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: "exportLayout") } }
    }

    static var logoURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("watermark-logo.png") }

    /// Applies frame + watermark to a finished linear image.
    func apply(_ input: CIImage) -> CIImage {
        var img = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        if let target = frame.size {
            let T = CGRect(origin: .zero, size: target)
            let sFill = max(target.width / img.extent.width, target.height / img.extent.height)
            let sFit = min(target.width / img.extent.width, target.height / img.extent.height)
            func centered(_ i: CIImage, _ s: CGFloat) -> CIImage {
                let scaled = i.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                return scaled.transformed(by: CGAffineTransform(translationX: (target.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                                y: (target.height - scaled.extent.height) / 2 - scaled.extent.minY))
            }
            switch fit {
            case .fill:
                img = centered(img, sFill).cropped(to: T)
            case .blur:
                let bg = centered(img, sFill).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 40])
                    .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.7]).cropped(to: T)
                img = centered(img, sFit).composited(over: bg).cropped(to: T)
            case .black, .white:
                let bg = CIImage(color: fit == .black ? .black : .white).cropped(to: T)
                img = centered(img, sFit).composited(over: bg).cropped(to: T)
            }
        }
        if watermark { img = addWatermark(img) }
        return img
    }

    private func addWatermark(_ img: CIImage) -> CIImage {
        let E = img.extent
        let short = min(E.width, E.height)
        var mark: CIImage?
        if useLogo, let logo = CIImage(contentsOf: ExportLayout.logoURL) {
            let h = short * CGFloat(size) * 2.2
            mark = logo.transformed(by: CGAffineTransform(scaleX: h / logo.extent.height, y: h / logo.extent.height))
        } else if !watermarkText.isEmpty {
            let font = UIFont.systemFont(ofSize: short * CGFloat(size), weight: .semibold)
            let shadow = NSShadow(); shadow.shadowColor = UIColor.black.withAlphaComponent(0.5); shadow.shadowBlurRadius = short * 0.004
            let text = NSAttributedString(string: watermarkText, attributes: [.font: font, .foregroundColor: UIColor.white, .shadow: shadow])
            mark = CIFilter(name: "CIAttributedTextImageGenerator", parameters: ["inputText": text, "inputScaleFactor": 1.0])?.outputImage
        }
        guard var m = mark else { return img }
        m = m.transformed(by: CGAffineTransform(translationX: -m.extent.minX, y: -m.extent.minY))
        // fade
        m = m.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
        let pad = short * 0.035
        let w = m.extent.width, h = m.extent.height
        let pos: CGPoint
        switch corner {
        case .bottomRight: pos = CGPoint(x: E.maxX - w - pad, y: E.minY + pad)
        case .bottomLeft: pos = CGPoint(x: E.minX + pad, y: E.minY + pad)
        case .topRight: pos = CGPoint(x: E.maxX - w - pad, y: E.maxY - h - pad)
        case .topLeft: pos = CGPoint(x: E.minX + pad, y: E.maxY - h - pad)
        case .center: pos = CGPoint(x: E.midX - w / 2, y: E.midY - h / 2)
        }
        return m.transformed(by: CGAffineTransform(translationX: pos.x, y: pos.y)).composited(over: img).cropped(to: E)
    }
}
