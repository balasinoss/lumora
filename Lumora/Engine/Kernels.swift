import CoreImage

/// Loads the Metal Core Image kernels compiled into default.metallib.
enum Kernels {
    static let library: Data = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("default.metallib missing from bundle")
        }
        return data
    }()

    private static func color(_ name: String) -> CIColorKernel {
        do { return try CIColorKernel(functionName: name, fromMetalLibraryData: library) }
        catch { fatalError("Kernel \(name) failed: \(error)") }
    }
    private static func general(_ name: String) -> CIKernel {
        do { return try CIKernel(functionName: name, fromMetalLibraryData: library) }
        catch { fatalError("Kernel \(name) failed: \(error)") }
    }

    static let lensCorrect = general("lensCorrect")
    static let caRemove = general("caRemove")
    static let defringe = general("defringe")
    static let tone = color("tone")
    static let localContrast = color("localContrast")
    static let dehaze = color("dehaze")
    static let darkChannel = color("darkChannel")
    static let colorMixer = color("colorMixer")
    static let colorGrade = color("colorGrade")
    static let chromaNR = color("chromaNR")
    static let lumaNR = color("lumaNR")
    static let sharpen = color("sharpen")
    static let vignette = color("vignette")
    static let grainBlend = color("grainBlend")
}

extension CIImage {
    /// Gaussian blur that keeps the original extent (no dark edges).
    func lumoraBlur(_ radius: CGFloat) -> CIImage {
        guard radius > 0.3 else { return self }
        return clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }
}
