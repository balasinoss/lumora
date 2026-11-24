import Foundation
import CoreGraphics

/// One colour band of the colour mixer (Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta).
struct HSLBand: Codable, Equatable {
    var hue: Double = 0          // -100...100
    var saturation: Double = 0   // -100...100
    var luminance: Double = 0    // -100...100
}

/// A colour-grading wheel.
struct GradeWheel: Codable, Equatable {
    var hue: Double = 0          // 0...360
    var saturation: Double = 0   // 0...100
    var luminance: Double = 0    // -100...100
}

struct CurvePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

enum CurveChannel: String, Codable, CaseIterable, Identifiable {
    case master = "RGB", red = "Red", green = "Green", blue = "Blue"
    var id: String { rawValue }
}

struct NormRect: Codable, Equatable {
    var x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1   // top-left origin, 0...1
    static let full = NormRect()
    var isFull: Bool { x <= 0.0001 && y <= 0.0001 && w >= 0.9999 && h >= 0.9999 }
}

/// Every adjustment the editor supports. Saved as JSON next to the original photo.
struct EditSettings: Codable, Equatable {
    // MARK: Profile
    var profile: String = "Color"
    var profileAmount: Double = 100

    // MARK: Light
    var exposure: Double = 0       // -5...5 EV
    var contrast: Double = 0       // -100...100
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0

    // MARK: Curves
    var curveMaster: [CurvePoint] = EditSettings.identityCurve
    var curveRed: [CurvePoint] = EditSettings.identityCurve
    var curveGreen: [CurvePoint] = EditSettings.identityCurve
    var curveBlue: [CurvePoint] = EditSettings.identityCurve

    // MARK: Colour
    var whiteBalance: String = "As Shot"   // As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash, Custom
    var temperature: Double? = nil          // RAW: kelvin. Non-RAW: nil = as shot
    var tempShift: Double = 0               // non-RAW relative temperature -100...100
    var tint: Double = 0                    // -150...150
    var vibrance: Double = 0
    var saturation: Double = 0
    var mixer: [HSLBand] = Array(repeating: HSLBand(), count: 8)
    var blackAndWhite: Bool = false
    var bwMix: [Double] = Array(repeating: 0, count: 8)

    // MARK: Colour grading
    var gradeShadows = GradeWheel()
    var gradeMidtones = GradeWheel()
    var gradeHighlights = GradeWheel()
    var gradeGlobal = GradeWheel()
    var gradeBlending: Double = 50
    var gradeBalance: Double = 0

    // MARK: Effects
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var vignette: Double = 0
    var vignetteMidpoint: Double = 50
    var vignetteRoundness: Double = 0
    var vignetteFeather: Double = 50
    var vignetteHighlights: Double = 0
    var grain: Double = 0
    var grainSize: Double = 25
    var grainRoughness: Double = 50

    // MARK: Detail
    var sharpening: Double = 0
    var sharpenRadius: Double = 1.0
    var sharpenDetail: Double = 25
    var sharpenMasking: Double = 0
    var noiseReduction: Double = 0
    var noiseDetail: Double = 50
    var noiseContrast: Double = 0
    var colorNoiseReduction: Double = 0
    var colorNoiseDetail: Double = 50
    var colorNoiseSmoothness: Double = 50

    // MARK: Optics
    var removeChromaticAberration: Bool = false
    var enableLensCorrection: Bool = false
    var lensProfileID: String? = nil        // nil = auto-detect from EXIF
    var lensDistortionAmount: Double = 100  // 0...200
    var lensVignetteAmount: Double = 100    // 0...200
    var manualDistortion: Double = 0        // -100...100
    var manualVignette: Double = 0          // -100...100
    var manualVignetteMidpoint: Double = 50
    var defringePurple: Double = 0          // 0...20
    var purpleHueLow: Double = 30
    var purpleHueHigh: Double = 70
    var defringeGreen: Double = 0           // 0...20
    var greenHueLow: Double = 40
    var greenHueHigh: Double = 60

    // MARK: Geometry
    var vertical: Double = 0
    var horizontal: Double = 0
    var rotate: Double = 0                  // -10...10 deg
    var aspect: Double = 0
    var scale: Double = 100                 // 50...150
    var offsetX: Double = 0
    var offsetY: Double = 0

    // MARK: Calibration
    var calRedHue: Double = 0
    var calRedSat: Double = 0
    var calGreenHue: Double = 0
    var calGreenSat: Double = 0
    var calBlueHue: Double = 0
    var calBlueSat: Double = 0
    var calShadowTint: Double = 0
    var hasCalibration: Bool { calRedHue != 0 || calRedSat != 0 || calGreenHue != 0 || calGreenSat != 0 || calBlueHue != 0 || calBlueSat != 0 }

    // MARK: Point colour & healing
    var pointColors: [PointColor] = []
    var healSpots: [HealSpot] = []

    // MARK: AI
    var aiDenoise: Bool = false
    var aiDenoiseAmount: Double = 50
    var masks: [MaskLayer] = []

    // MARK: Crop
    var crop: NormRect = .full
    var cropAspect: String = "Original"
    var straighten: Double = 0              // -45...45 deg
    var rotation90: Int = 0                 // quarter turns clockwise
    var flipH: Bool = false
    var flipV: Bool = false

    static let identityCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    /// Default settings for a RAW file get the usual RAW detail defaults.
    static func defaults(isRAW: Bool) -> EditSettings {
        var s = EditSettings()
        if isRAW {
            s.sharpening = 40
            s.colorNoiseReduction = 25
        }
        return s
    }

    func curve(_ c: CurveChannel) -> [CurvePoint] {
        switch c {
        case .master: return curveMaster
        case .red: return curveRed
        case .green: return curveGreen
        case .blue: return curveBlue
        }
    }
    mutating func setCurve(_ c: CurveChannel, _ pts: [CurvePoint]) {
        switch c {
        case .master: curveMaster = pts
        case .red: curveRed = pts
        case .green: curveGreen = pts
        case .blue: curveBlue = pts
        }
    }

    var hasCurves: Bool {
        [curveMaster, curveRed, curveGreen, curveBlue].contains { $0 != EditSettings.identityCurve }
    }
    var hasMixer: Bool { mixer != Array(repeating: HSLBand(), count: 8) }
    var hasGrading: Bool {
        [gradeShadows, gradeMidtones, gradeHighlights, gradeGlobal].contains { $0.saturation != 0 || $0.luminance != 0 }
    }

    // MARK: Tolerant decoding (new keys added in later versions fall back to defaults)
    static func decode(_ data: Data) -> EditSettings? {
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(EditSettings()),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return nil }
        for (k, v) in stored { merged[k] = v }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(EditSettings.self, from: mergedData)
    }
}

/// Adjust one picked colour (like a targeted HSL).
struct PointColor: Codable, Equatable, Identifiable {
    var id = UUID()
    var r: Double, g: Double, b: Double      // sampled colour, gamma sRGB 0...1
    var hueShift: Double = 0                  // -100...100
    var satShift: Double = 0
    var lumShift: Double = 0
    var range: Double = 50                    // 0...100
}

/// Heal / clone spot (normalised coordinates in the original frame, top-left origin).
struct HealSpot: Codable, Equatable, Identifiable {
    var id = UUID()
    var x: Double, y: Double
    var srcX: Double, srcY: Double
    var radius: Double                        // fraction of the short side
    var feather: Double = 0.5
    var clone: Bool = false
    var shift: [Double] = [0, 0, 0]           // colour correction (linear RGB) for heal mode
}

enum ColorBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }
    var name: String { ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue] }
    /// Centre hue in degrees.
    var hue: Double { [0, 30, 60, 120, 180, 240, 270, 300][rawValue] }
}
