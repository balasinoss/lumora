import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Wraps an original photo file (RAW, DNG, HEIC, JPEG, PNG…) and produces the linear "base"
/// image that the pipeline starts from.
final class PhotoSource {
    let url: URL
    let isRAW: Bool
    let properties: [String: Any]
    let fullSize: CGSize            // oriented pixel size

    // EXIF-derived info for lens corrections
    let lensModel: String?
    let lensMake: String?
    let cameraMake: String?
    let cameraModel: String?
    let focalLength: Double
    let focal35: Double
    let aperture: Double

    /// As-shot white balance for RAW files.
    private(set) var asShotTemperature: Double = 5500
    private(set) var asShotTint: Double = 0

    private var previewCache: (key: String, image: CIImage)?
    private var averageCache: [Double]?
    private let lock = NSLock()

    static let rawTypes: Set<String> = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
                                         "pef", "srw", "x3f", "erf", "3fr", "fff", "iiq", "mos", "mrw", "dcr", "kdc", "rwl", "gpr"]

    init?(url: URL) {
        self.url = url
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        properties = props
        let ext = url.pathExtension.lowercased()
        var raw = PhotoSource.rawTypes.contains(ext)
        if let t = CGImageSourceGetType(src) as String?, let ut = UTType(t), ut.conforms(to: .rawImage) { raw = true }
        isRAW = raw

        let w = (props[kCGImagePropertyPixelWidth as String] as? Double) ?? 0
        let h = (props[kCGImagePropertyPixelHeight as String] as? Double) ?? 0
        let orientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        fullSize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        lensModel = (exif[kCGImagePropertyExifLensModel as String] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel as String] as? String)
        lensMake = exif[kCGImagePropertyExifLensMake as String] as? String
        cameraMake = tiff[kCGImagePropertyTIFFMake as String] as? String
        cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
        focalLength = (exif[kCGImagePropertyExifFocalLength as String] as? Double) ?? 0
        focal35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double) ?? 0
        aperture = (exif[kCGImagePropertyExifFNumber as String] as? Double) ?? 0

        if isRAW, let f = CIRAWFilter(imageURL: url) {
            asShotTemperature = Double(f.neutralTemperature)
            asShotTint = Double(f.neutralTint)
        }
    }

    /// Crop factor of the camera that made this photo, if it can be determined.
    var cropFactor: Double? {
        if focal35 > 0 && focalLength > 0 { return focal35 / focalLength }
        return LensDatabase.shared.cameraCropFactor(make: cameraMake, model: cameraModel)
    }

    var dimensionsText: String { "\(Int(fullSize.width)) × \(Int(fullSize.height))" }

    // MARK: Base image

    var denoisedURL: URL { AIDenoise.outputURL(url.deletingLastPathComponent()) }
    var hasDenoised: Bool { FileManager.default.fileExists(atPath: denoisedURL.path) }

    private func rawKey(_ s: EditSettings) -> String {
        var dn = ""
        if s.aiDenoise && hasDenoised {
            let attrs = try? FileManager.default.attributesOfItem(atPath: denoisedURL.path)
            let date = attrs?[.modificationDate] as? Date
            dn = "dn\(date?.timeIntervalSince1970 ?? 0)"
        }
        guard isRAW else { return "std" + dn }
        if !dn.isEmpty { return "raw\(s.temperature ?? -1)|\(s.tint)|\(s.whiteBalance)" + dn }
        return "\(s.temperature ?? -1)|\(s.tint)|\(s.whiteBalance)|\(s.noiseReduction)|\(s.colorNoiseReduction)"
    }

    func clearCache() {
        lock.lock(); previewCache = nil; lock.unlock()
    }

    /// Fast, small preview straight from the file (uses the embedded JPEG for RAW files).
    func quickImage(maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Builds the base image (linear, oriented, origin at 0,0).
    /// maxDimension = nil for full resolution.
    func makeBase(settings s: EditSettings, maxDimension: CGFloat?, allowDenoised: Bool = true) -> CIImage? {
        var img: CIImage?
        let scale: CGFloat = maxDimension.map { min(1, $0 / max(fullSize.width, fullSize.height)) } ?? 1
        if allowDenoised && s.aiDenoise && hasDenoised, var d = CIImage(contentsOf: denoisedURL) {
            if scale < 1 {
                d = d.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
            if isRAW {
                // denoised file has as-shot white balance baked in; apply the difference
                let (t, ti) = rawWhiteBalance(s)
                if abs(t - asShotTemperature) > 1 || abs(ti - asShotTint) > 0.5 {
                    d = d.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: CGFloat(t), y: CGFloat(ti)),
                        "inputTargetNeutral": CIVector(x: CGFloat(asShotTemperature), y: CGFloat(asShotTint))])
                }
            }
            img = d
        } else if isRAW, let f = CIRAWFilter(imageURL: url) {
            f.scaleFactor = Float(scale)
            let (t, ti) = rawWhiteBalance(s)
            f.neutralTemperature = Float(t)
            f.neutralTint = Float(ti)
            f.luminanceNoiseReductionAmount = Float(min(1, s.noiseReduction / 100))
            f.colorNoiseReductionAmount = Float(min(1, s.colorNoiseReduction / 100))
            if f.isSharpnessSupported { f.sharpnessAmount = 0 }
            if f.isLensCorrectionSupported { f.isLensCorrectionEnabled = true }
            img = f.outputImage
        } else {
            img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            if let i = img, scale < 1 {
                img = i.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
        }
        guard let out = img else { return nil }
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
    }

    func rawWhiteBalance(_ s: EditSettings) -> (Double, Double) {
        switch s.whiteBalance {
        case "Daylight": return (5500, 10)
        case "Cloudy": return (6500, 10)
        case "Shade": return (7500, 10)
        case "Tungsten": return (2850, 0)
        case "Fluorescent": return (3800, 21)
        case "Flash": return (5500, 0)
        case "Custom": return (s.temperature ?? asShotTemperature, s.tint)
        default: return (asShotTemperature, asShotTint + (s.whiteBalance == "As Shot" ? 0 : 0))
        }
    }

    /// Cached low-resolution base used for the live preview. Rendered to a float bitmap so slider
    /// changes do not re-decode the file.
    func previewBase(settings s: EditSettings, context: CIContext, maxDimension: CGFloat = 2048) -> CIImage? {
        let key = rawKey(s) + "@\(maxDimension)"
        lock.lock()
        if let c = previewCache, c.key == key { lock.unlock(); return c.image }
        lock.unlock()
        guard let base = makeBase(settings: s, maxDimension: maxDimension),
              let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let cg = context.createCGImage(base, from: base.extent, format: .RGBAh, colorSpace: cs) else { return nil }
        let img = CIImage(cgImage: cg)
        lock.lock(); previewCache = (key, img); lock.unlock()
        return img
    }

    /// Average linear colour of the photo (for Auto white balance / Auto tone).
    func averageColor(context: CIContext) -> [Double] {
        if let a = averageCache { return a }
        guard let base = previewBase(settings: .defaults(isRAW: isRAW), context: context, maxDimension: 512) else { return [0.18, 0.18, 0.18] }
        let avg = base.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: base.extent)])
        var px = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let a = [Double(px[0]), Double(px[1]), Double(px[2])]
        averageCache = a
        return a
    }
}
