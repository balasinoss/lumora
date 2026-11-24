import CoreML
import CoreImage
import CoreVideo
import UIKit

/// Loads the Core ML models compiled into the app.
enum AIModels {
    private static func load(_ name: String, units: MLComputeUnits = .all) -> MLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            print("Model \(name) missing"); return nil
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try? MLModel(contentsOf: url, configuration: cfg)
    }

    static let denoiser: MLModel? = load("Denoiser")
    static let sky: MLModel? = load("SkySegmenter")
    static let clipImage: MLModel? = load("ClipImage")
    static let clipText: MLModel? = load("ClipText")
    static let upscaler: MLModel? = load("Upscaler")

    /// Fills a [1,3,H,W] Float32 multi-array from an RGBA8 bitmap (values 0...1).
    static func planarArray(from cg: CGImage, width: Int, height: Int) -> MLMultiArray? {
        guard let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32),
              let rgba = rgbaBytes(cg, width: width, height: height) else { return nil }
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * width * height)
        let plane = width * height
        for i in 0..<plane {
            p[i] = Float(rgba[i * 4]) / 255
            p[plane + i] = Float(rgba[i * 4 + 1]) / 255
            p[2 * plane + i] = Float(rgba[i * 4 + 2]) / 255
        }
        return arr
    }

    /// Draws a CGImage into an RGBA8 buffer of the given size (stretching).
    static func rgbaBytes(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }

    static func pixelBuffer(from cg: CGImage, width: Int, height: Int, format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let info: UInt32 = format == kCVPixelFormatType_32BGRA
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }

    /// Reads any multi-array output as [Float].
    static func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        var out = [Float](repeating: 0, count: n)
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { out[i] = p[i] }
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: n)
            for i in 0..<n { out[i] = Float(p[i]) }
        case .double:
            let p = a.dataPointer.bindMemory(to: Double.self, capacity: n)
            for i in 0..<n { out[i] = Float(p[i]) }
        default:
            for i in 0..<n { out[i] = a[i].floatValue }
        }
        return out
    }

    /// Center-crops a CGImage to a square.
    static func centerSquare(_ cg: CGImage) -> CGImage {
        let s = min(cg.width, cg.height)
        let r = CGRect(x: (cg.width - s) / 2, y: (cg.height - s) / 2, width: s, height: s)
        return cg.cropping(to: r) ?? cg
    }
}
