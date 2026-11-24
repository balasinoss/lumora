import CoreImage
import UIKit

/// Turns a base image + EditSettings into the final edited image.
final class RenderPipeline {
    static let shared = RenderPipeline()

    let context: CIContext = {
        let ws = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [.workingColorSpace: ws, .cacheIntermediates: false])
        }
        return CIContext(options: [.workingColorSpace: ws])
    }()

    struct Info {
        /// preview short side / full-resolution short side, for pixel-based parameters
        var pixelScale: CGFloat = 1
        var isRAW: Bool = false
        var lens: LensProfile? = nil
        var focal: Double = 0
        var aperture: Double = 0
        var imageCrop: Double? = nil
        var averageColor: [Double] = [0.18, 0.18, 0.18]
    }

    static func info(for source: PhotoSource, settings: EditSettings, pixelScale: CGFloat) -> Info {
        var i = Info()
        i.pixelScale = pixelScale
        i.isRAW = source.isRAW
        i.focal = source.focalLength
        i.aperture = source.aperture
        i.imageCrop = source.cropFactor
        if settings.enableLensCorrection || settings.removeChromaticAberration {
            if let id = settings.lensProfileID { i.lens = LensDatabase.shared.lens(id: id) }
            else { i.lens = LensDatabase.shared.match(lensModel: source.lensModel, lensMake: source.lensMake, cameraMake: source.cameraMake) }
        }
        if settings.whiteBalance == "Auto" {
            i.averageColor = source.averageColor(context: RenderPipeline.shared.context)
        }
        return i
    }

    // MARK: - Main pipeline

    func process(_ base: CIImage, settings raw: EditSettings, info: Info) -> CIImage {
        let s = Profiles.apply(raw)
        var img = base
        let E0 = img.extent
        let short0 = min(E0.width, E0.height)
        let px = info.pixelScale

        // 1. Optics (linear light)
        img = applyLens(img, s: s, info: info)

        // 2. White balance
        if s.whiteBalance == "Auto" {
            let a = info.averageColor
            let l = (a[0] * 0.2126 + a[1] * 0.7152 + a[2] * 0.0722)
            func g(_ c: Double) -> CGFloat { CGFloat(pow(l / max(c, 1e-4), 0.85)) }
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g(a[0]), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g(a[1]), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g(a[2]), w: 0)])
        }
        if !info.isRAW && (s.tempShift != 0 || s.tint != 0) {
            let neutral = 6500 * pow(2.0, s.tempShift / 100)
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(neutral), y: CGFloat(s.tint)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }

        // 3. Exposure
        if s.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure])
        }

        // 4. To perceptual (gamma) space
        img = img.applyingFilter("CILinearToSRGBToneCurve")

        // 5. Chromatic aberration (auto) + defringe
        if s.removeChromaticAberration && (info.lens?.tca.isEmpty ?? true) {
            let wide = img.lumoraBlur(max(2, 6 * px))
            img = Kernels.caRemove.apply(extent: img.extent, roiCallback: { _, r in r.insetBy(dx: -6, dy: -6) },
                                          arguments: [img.clampedToExtent(), wide.clampedToExtent(), 0.9, max(1, 2 * px)])?.cropped(to: E0) ?? img
        }
        if s.defringePurple > 0 || s.defringeGreen > 0 {
            let r = (1 + max(s.defringePurple, s.defringeGreen) * 0.3) + 2
            img = Kernels.defringe.apply(extent: img.extent, roiCallback: { _, rect in rect.insetBy(dx: -r, dy: -r) },
                                          arguments: [img.clampedToExtent(), s.defringePurple,
                                                      CIVector(x: hueDeg(s.purpleHueLow, from: 240, to: 340), y: hueDeg(s.purpleHueHigh, from: 240, to: 340)),
                                                      s.defringeGreen,
                                                      CIVector(x: hueDeg(s.greenHueLow, from: 60, to: 180), y: hueDeg(s.greenHueHigh, from: 60, to: 180))])?.cropped(to: E0) ?? img
        }

        // 6. Noise reduction (RAW files use the RAW decoder's noise reduction)
        if !info.isRAW {
            if s.noiseReduction > 0 {
                let b = img.lumoraBlur(max(0.8, (1 + s.noiseReduction / 100 * 2.5) * px))
                img = Kernels.lumaNR.apply(extent: img.extent, arguments: [img, b, s.noiseReduction / 100, s.noiseDetail / 100, s.noiseContrast / 100]) ?? img
            }
            if s.colorNoiseReduction > 0 {
                let b = img.lumoraBlur(max(1.5, (2 + s.colorNoiseReduction / 100 * 6 * (0.5 + s.colorNoiseSmoothness / 100)) * px))
                img = Kernels.chromaNR.apply(extent: img.extent, arguments: [img, b, min(1, s.colorNoiseReduction / 60), s.colorNoiseDetail / 100]) ?? img
            }
        }

        // 7. Tone
        if s.highlights != 0 || s.shadows != 0 || s.whites != 0 || s.blacks != 0 || s.contrast != 0 {
            let local = img.lumoraBlur(short0 * 0.012)
            img = Kernels.tone.apply(extent: img.extent, arguments: [img, local,
                CIVector(x: s.highlights / 100, y: s.shadows / 100, z: s.whites / 100, w: s.blacks / 100), s.contrast / 100]) ?? img
        }

        // 8. Dehaze, clarity, texture
        if s.dehaze != 0 {
            let dark = (Kernels.darkChannel.apply(extent: img.extent, arguments: [img]) ?? img).lumoraBlur(short0 * 0.02)
            img = Kernels.dehaze.apply(extent: img.extent, arguments: [img, dark, s.dehaze / 100]) ?? img
        }
        if s.clarity != 0 {
            let b = img.lumoraBlur(short0 * 0.018)
            img = Kernels.localContrast.apply(extent: img.extent, arguments: [img, b, s.clarity / 100 * 1.1, 1.0]) ?? img
        }
        if s.texture != 0 {
            let b = img.lumoraBlur(max(1, short0 * 0.0035))
            img = Kernels.localContrast.apply(extent: img.extent, arguments: [img, b, s.texture / 100 * 1.6, 0.0]) ?? img
        }

        // 9. Curves
        if s.hasCurves {
            img = img.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": Curves.lutData(s),
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
        }

        // 10. Colour mixer, vibrance, saturation, B&W
        if s.hasMixer || s.vibrance != 0 || s.saturation != 0 || s.blackAndWhite {
            let m = s.mixer
            func v4(_ a: [Double], _ o: Int) -> CIVector { CIVector(x: a[o], y: a[o + 1], z: a[o + 2], w: a[o + 3]) }
            let hue = m.map { $0.hue / 100 }, sat = m.map { $0.saturation / 100 }, lum = m.map { $0.luminance / 100 }
            let bw = s.bwMix.map { $0 / 100 }
            img = Kernels.colorMixer.apply(extent: img.extent, arguments: [img,
                v4(hue, 0), v4(hue, 4), v4(sat, 0), v4(sat, 4), v4(lum, 0), v4(lum, 4),
                s.vibrance / 100, s.saturation / 100, s.blackAndWhite ? 1.0 : 0.0, v4(bw, 0), v4(bw, 4)]) ?? img
        }

        // 11. Colour grading
        if s.hasGrading {
            img = Kernels.colorGrade.apply(extent: img.extent, arguments: [img,
                wheelVector(s.gradeShadows), wheelVector(s.gradeMidtones), wheelVector(s.gradeHighlights), wheelVector(s.gradeGlobal),
                s.gradeBlending / 100, s.gradeBalance / 100]) ?? img
        }

        // 12. Sharpening
        if s.sharpening > 0 {
            let b = img.lumoraBlur(max(0.5, s.sharpenRadius * px))
            let wide = img.lumoraBlur(max(1.5, 3 * px))
            img = Kernels.sharpen.apply(extent: img.extent, arguments: [img, b, wide, s.sharpening / 100 * 1.8, s.sharpenDetail / 100, s.sharpenMasking / 100]) ?? img
        }

        // 13. Geometry: 90° rotation & flips, transform panel, straighten + crop
        img = applyOrientation(img, s: s)
        img = applyGeometry(img, s: s)
        img = applyCrop(img, s: s)
        let E = img.extent

        // 14. Post-crop vignette & grain
        if s.vignette != 0 {
            img = Kernels.vignette.apply(extent: E, arguments: [img,
                CIVector(x: E.midX, y: E.midY), CIVector(x: E.width / 2, y: E.height / 2),
                s.vignette / 100, s.vignetteMidpoint / 100, s.vignetteRoundness / 100, s.vignetteFeather / 100, s.vignetteHighlights / 100]) ?? img
        }
        if s.grain > 0 {
            let size = max(1, (1 + s.grainSize / 100 * 3) * px)
            var noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: size, y: size))
            noise = noise.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.3, (1 - s.grainRoughness / 100) * size * 0.6)])
                .cropped(to: E)
            img = Kernels.grainBlend.apply(extent: E, arguments: [img, noise, s.grain / 100 * 0.28]) ?? img
        }

        // 15. Back to linear for the output colour space
        img = img.applyingFilter("CISRGBToneCurveToLinear")
        return img.transformed(by: CGAffineTransform(translationX: -E.origin.x, y: -E.origin.y))
    }

    private func hueDeg(_ v: Double, from: Double, to: Double) -> CGFloat { CGFloat(from + (to - from) * v / 100) }

    private func wheelVector(_ w: GradeWheel) -> CIVector {
        guard w.saturation > 0 || w.luminance != 0 else { return CIVector(x: 0, y: 0, z: 0, w: 0) }
        let c = UIColor(hue: CGFloat(w.hue / 360), saturation: 1, brightness: 1, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let k = CGFloat(w.saturation / 100) * 0.22
        return CIVector(x: (r - l) * k, y: (g - l) * k, z: (b - l) * k, w: CGFloat(w.luminance / 100) * 0.2)
    }

    // MARK: Lens

    private func applyLens(_ img: CIImage, s: EditSettings, info: Info) -> CIImage {
        var co = LensCoefficients()
        if let lens = info.lens {
            co = LensCoefficients.make(profile: lens, focal: info.focal, aperture: info.aperture, imageCrop: info.imageCrop,
                                       useDistortion: s.enableLensCorrection, distortionAmount: s.lensDistortionAmount,
                                       useTCA: s.removeChromaticAberration || s.enableLensCorrection,
                                       useVignetting: s.enableLensCorrection, vignetteAmount: s.lensVignetteAmount)
        }
        let manualDist = -s.manualDistortion / 100 * 0.18
        let manualVig = s.manualVignette / 100
        if co.isIdentity && manualDist == 0 && manualVig == 0 { return img }

        let E = img.extent
        let center = CGPoint(x: E.midX, y: E.midY)
        // r = 1 at half the short side (distortion/TCA) or half the diagonal (vignetting), in calibration space.
        let distNorm = min(E.width, E.height) / 2 / CGFloat(co.cropRatio)
        let vigNorm = hypot(E.width, E.height) / 2 / CGFloat(co.cropRatio)

        func factor(_ ru: Double) -> Double {
            let d = co.dist
            return (d.d + d.c * ru + d.b * ru * ru + d.a * ru * ru * ru + d.e * ru * ru * ru * ru) * (1 + manualDist * ru * ru)
        }
        // Auto-scale so no empty borders appear (sample positions must stay inside the source).
        var fit = 1.0
        let pts = [CGPoint(x: E.width / 2, y: E.height / 2), CGPoint(x: E.width / 2, y: 0), CGPoint(x: 0, y: E.height / 2)]
        for _ in 0..<60 {
            var ok = true
            for p in pts {
                let ru = Double(hypot(p.x, p.y)) * fit / Double(distNorm)
                let f = factor(ru) * fit
                if abs(Double(p.x) * f) > Double(E.width / 2) + 0.5 || abs(Double(p.y) * f) > Double(E.height / 2) + 0.5 { ok = false }
            }
            if ok { break }
            fit -= 0.005
        }
        let maxShift = CGFloat(abs(1 - factor(Double(hypot(E.width, E.height) / 2 / distNorm)) * fit)) * hypot(E.width, E.height) / 2 + 8

        let out = Kernels.lensCorrect.apply(extent: E, roiCallback: { _, r in r.insetBy(dx: -maxShift, dy: -maxShift) }, arguments: [
            img.clampedToExtent(),
            CIVector(cgPoint: center), distNorm,
            CIVector(x: co.dist.a, y: co.dist.b, z: co.dist.c, w: co.dist.d), co.dist.e,
            CIVector(x: co.tcaR.v, y: co.tcaR.c, z: co.tcaR.b), CIVector(x: co.tcaB.v, y: co.tcaB.c, z: co.tcaB.b),
            vigNorm, CIVector(x: co.vig.k1, y: co.vig.k2, z: co.vig.k3),
            fit, manualDist, CIVector(x: manualVig, y: s.manualVignetteMidpoint / 100)])
        return out?.cropped(to: E) ?? img
    }

    // MARK: Geometry

    private func applyOrientation(_ img: CIImage, s: EditSettings) -> CIImage {
        var out = img
        let turns = ((s.rotation90 % 4) + 4) % 4
        if turns > 0 {
            let o: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
            out = out.oriented(o[turns])
        }
        if s.flipH { out = out.oriented(.upMirrored) }
        if s.flipV { out = out.oriented(.downMirrored) }
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
    }

    private func applyGeometry(_ img: CIImage, s: EditSettings) -> CIImage {
        guard s.vertical != 0 || s.horizontal != 0 || s.rotate != 0 || s.aspect != 0 || s.scale != 100 || s.offsetX != 0 || s.offsetY != 0 else { return img }
        let E = img.extent
        let w = E.width, h = E.height
        var out = img
        if s.vertical != 0 || s.horizontal != 0 {
            let v = CGFloat(s.vertical / 100) * 0.3 * w
            let hz = CGFloat(s.horizontal / 100) * 0.3 * h
            out = out.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(x: -v, y: h + hz * 0),
                "inputTopRight": CIVector(x: w + v, y: h + hz),
                "inputBottomLeft": CIVector(x: 0, y: 0),
                "inputBottomRight": CIVector(x: w, y: -hz)])
            // perspective can move the image; re-centre on the original frame
            let oe = out.extent
            out = out.transformed(by: CGAffineTransform(translationX: E.midX - oe.midX, y: E.midY - oe.midY))
        }
        var t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        let ax = s.aspect > 0 ? 1 + CGFloat(s.aspect / 100) * 0.5 : 1
        let ay = s.aspect < 0 ? 1 - CGFloat(s.aspect / 100) * 0.5 : 1
        let sc = CGFloat(s.scale / 100)
        t = t.concatenating(CGAffineTransform(scaleX: ax * sc, y: ay * sc))
        t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(-s.rotate * .pi / 180)))
        t = t.concatenating(CGAffineTransform(translationX: w / 2 + CGFloat(s.offsetX / 100) * w, y: h / 2 - CGFloat(s.offsetY / 100) * h))
        out = out.transformed(by: t)
        let bg = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: E)
        return out.composited(over: bg).cropped(to: E)
    }

    /// Straighten (rotate + auto-fill) and crop.
    func applyCrop(_ img: CIImage, s: EditSettings) -> CIImage {
        var out = img
        let E = img.extent
        if s.straighten != 0 {
            let a = CGFloat(s.straighten * .pi / 180)
            let w = E.width, h = E.height
            let fill = max((w * abs(cos(a)) + h * abs(sin(a))) / w, (w * abs(sin(a)) + h * abs(cos(a))) / h)
            let t = CGAffineTransform(translationX: -E.midX, y: -E.midY)
                .concatenating(CGAffineTransform(scaleX: fill, y: fill))
                .concatenating(CGAffineTransform(rotationAngle: -a))
                .concatenating(CGAffineTransform(translationX: E.midX, y: E.midY))
            out = out.transformed(by: t).cropped(to: E)
        }
        if !s.crop.isFull {
            let c = s.crop
            let r = CGRect(x: E.minX + CGFloat(c.x) * E.width,
                           y: E.minY + CGFloat(1 - c.y - c.h) * E.height,
                           width: CGFloat(c.w) * E.width, height: CGFloat(c.h) * E.height).integral
            out = out.cropped(to: r)
        }
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
    }

    /// Image before crop/straighten, used by the crop tool.
    func processUncropped(_ base: CIImage, settings: EditSettings, info: Info) -> CIImage {
        var s = settings
        s.crop = .full
        s.straighten = 0
        s.vignette = 0
        return process(base, settings: s, info: info)
    }

    // MARK: - Output helpers

    func cgImage(_ img: CIImage) -> CGImage? {
        context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// 64-bin RGB histogram of a (linear) image, values normalised to 0...1.
    func histogram(_ img: CIImage) -> [[Float]] {
        let small = img.applyingFilter("CILinearToSRGBToneCurve")
        let scale = min(1, 400 / max(small.extent.width, small.extent.height))
        let s2 = small.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let h = s2.applyingFilter("CIAreaHistogram", parameters: [kCIInputExtentKey: CIVector(cgRect: s2.extent), "inputCount": 64, kCIInputScaleKey: 1])
        var px = [Float](repeating: 0, count: 64 * 4)
        context.render(h, toBitmap: &px, rowBytes: 64 * 16, bounds: CGRect(x: 0, y: 0, width: 64, height: 1), format: .RGBAf, colorSpace: nil)
        var r = [Float](), g = [Float](), b = [Float]()
        for i in 0..<64 { r.append(px[i * 4]); g.append(px[i * 4 + 1]); b.append(px[i * 4 + 2]) }
        let m = max(r.max() ?? 1, g.max() ?? 1, b.max() ?? 1, 1e-6)
        return [r.map { $0 / m }, g.map { $0 / m }, b.map { $0 / m }]
    }

    enum ExportFormat: String, CaseIterable, Identifiable { case jpeg = "JPEG", heic = "HEIC", png = "PNG"; var id: String { rawValue } }

    func encode(_ img: CIImage, format: ExportFormat, quality: Double, maxLongEdge: CGFloat?, properties: [String: Any]) -> Data? {
        var out = img
        if let m = maxLongEdge, max(img.extent.width, img.extent.height) > m {
            let k = m / max(img.extent.width, img.extent.height)
            out = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        }
        out = out.cropped(to: out.extent.integral)
        // keep EXIF but drop orientation (pixels are already upright)
        var props = properties
        props[kCGImagePropertyOrientation as String] = 1
        out = out.settingProperties(props)
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        let q: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        switch format {
        case .jpeg: return context.jpegRepresentation(of: out, colorSpace: cs, options: q)
        case .heic: return context.heifRepresentation(of: out, format: .RGBA8, colorSpace: cs, options: q)
        case .png: return context.pngRepresentation(of: out, format: .RGBA8, colorSpace: cs, options: [:])
        }
    }

    /// Full-resolution render of a photo with its settings.
    func renderFull(source: PhotoSource, settings: EditSettings, maxDimension: CGFloat? = nil) -> CIImage? {
        guard let base = source.makeBase(settings: settings, maxDimension: maxDimension) else { return nil }
        let full = min(source.fullSize.width, source.fullSize.height)
        let info = RenderPipeline.info(for: source, settings: settings, pixelScale: min(base.extent.width, base.extent.height) / max(full, 1))
        return process(base, settings: settings, info: info)
    }
}

// MARK: - Tone curves

enum Curves {
    /// Monotone cubic interpolation through control points.
    static func evaluate(_ pts: [CurvePoint], _ x: Double) -> Double {
        let p = pts.sorted { $0.x < $1.x }
        guard p.count >= 2 else { return x }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        let n = p.count
        var d = [Double](repeating: 0, count: n - 1), m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-6) }
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = p[k + 1].x - p[k].x
        let t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
        return min(max(y, 0), 1)
    }

    static func lutData(_ s: EditSettings) -> Data {
        var f = [Float]()
        let n = 256
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            let mx = evaluate(s.curveMaster, x)
            let r = evaluate(s.curveRed, mx), g = evaluate(s.curveGreen, mx), b = evaluate(s.curveBlue, mx)
            f.append(Float(r)); f.append(Float(g)); f.append(Float(b))
        }
        return f.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
