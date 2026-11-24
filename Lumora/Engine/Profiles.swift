import Foundation

/// Built-in looks ("profiles"). Each one is a set of offsets on top of the user's sliders,
/// scaled by the profile amount.
enum Profiles {
    static let all: [String] = ["Color", "Vivid", "Portrait", "Landscape", "Matte", "Warm Film", "Cool Film",
                                "Cinematic", "Mono", "Mono Contrast", "Mono Soft"]

    static func apply(_ input: EditSettings) -> EditSettings {
        var s = input
        let k = s.profileAmount / 100
        guard s.profile != "Color", k > 0 else { return s }
        func add(_ kp: WritableKeyPath<EditSettings, Double>, _ v: Double) { s[keyPath: kp] += v * k }
        switch s.profile {
        case "Vivid":
            add(\.contrast, 15); add(\.vibrance, 25); add(\.saturation, 8); add(\.clarity, 6)
        case "Portrait":
            add(\.contrast, -8); add(\.vibrance, 8); add(\.saturation, -5); add(\.shadows, 10)
            s.mixer[1].luminance += 10 * k; s.mixer[1].saturation -= 8 * k
        case "Landscape":
            add(\.vibrance, 30); add(\.clarity, 12); add(\.dehaze, 6); add(\.highlights, -15)
            s.mixer[3].saturation += 15 * k; s.mixer[5].saturation += 12 * k; s.mixer[5].luminance -= 10 * k
        case "Matte":
            add(\.contrast, -15); add(\.saturation, -12)
            if s.curveMaster == EditSettings.identityCurve {
                s.curveMaster = [CurvePoint(x: 0, y: 0.09 * k), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1 - 0.05 * k)]
            }
        case "Warm Film":
            add(\.contrast, 8); add(\.saturation, -10); add(\.grain, 15)
            s.gradeShadows.hue = 200; s.gradeShadows.saturation += 12 * k
            s.gradeHighlights.hue = 40; s.gradeHighlights.saturation += 22 * k
            if s.curveMaster == EditSettings.identityCurve {
                s.curveMaster = [CurvePoint(x: 0, y: 0.05 * k), CurvePoint(x: 1, y: 1)]
            }
        case "Cool Film":
            add(\.contrast, 6); add(\.saturation, -15); add(\.grain, 12)
            s.gradeShadows.hue = 215; s.gradeShadows.saturation += 20 * k
            s.gradeHighlights.hue = 55; s.gradeHighlights.saturation += 8 * k
        case "Cinematic":
            add(\.contrast, 12); add(\.highlights, -20); add(\.saturation, -8)
            s.gradeShadows.hue = 190; s.gradeShadows.saturation += 28 * k
            s.gradeHighlights.hue = 32; s.gradeHighlights.saturation += 25 * k
        case "Mono":
            s.blackAndWhite = true
        case "Mono Contrast":
            s.blackAndWhite = true; add(\.contrast, 30); add(\.clarity, 15)
            s.bwMix[5] -= 25 * k; s.bwMix[0] += 10 * k
        case "Mono Soft":
            s.blackAndWhite = true; add(\.contrast, -20); add(\.shadows, 15)
        default: break
        }
        return s
    }
}
