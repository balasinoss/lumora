import Foundation
import CoreGraphics

enum MaskKind: String, Codable, CaseIterable {
    case subject, sky, background, people, person, brush, linear, radial
    case object, faceSkin, eyes, lips, teeth

    var title: String {
        switch self {
        case .subject: return "Subject"
        case .sky: return "Sky"
        case .background: return "Background"
        case .people: return "People"
        case .person: return "Person"
        case .brush: return "Brush"
        case .linear: return "Linear Gradient"
        case .radial: return "Radial Gradient"
        case .object: return "Object"
        case .faceSkin: return "Face Skin"
        case .eyes: return "Eyes"
        case .lips: return "Lips"
        case .teeth: return "Teeth"
        }
    }
    var icon: String {
        switch self {
        case .subject: return "person.crop.square"
        case .sky: return "cloud.sun"
        case .background: return "photo"
        case .people, .person: return "person.2"
        case .brush: return "paintbrush.pointed"
        case .linear: return "square.bottomhalf.filled"
        case .radial: return "circle.dashed"
        case .object: return "rectangle.dashed"
        case .faceSkin: return "face.smiling"
        case .eyes: return "eye"
        case .lips: return "mouth"
        case .teeth: return "mouth.fill"
        }
    }
    var isAI: Bool { [.subject, .sky, .background, .people, .person, .faceSkin, .eyes, .lips, .teeth].contains(self) }
}

struct NPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

/// A brush stroke in normalised image coordinates (0...1, top-left origin).
struct BrushStroke: Codable, Equatable {
    var points: [NPoint] = []
    var size: Double = 0.06          // diameter, fraction of the image's short side
    var feather: Double = 0.5        // 0 hard ... 1 soft
    var flow: Double = 1.0
    var erase: Bool = false
}

struct MaskLinearGradient: Codable, Equatable {
    var start = NPoint(x: 0.5, y: 0.25)   // fully masked side
    var end = NPoint(x: 0.5, y: 0.6)      // fully unmasked side
}

struct MaskRadialGradient: Codable, Equatable {
    var center = NPoint(x: 0.5, y: 0.5)
    var radiusX: Double = 0.25            // fraction of width
    var radiusY: Double = 0.25            // fraction of height
    var feather: Double = 0.5
    var inside: Bool = true               // true = adjust inside the ellipse
}

/// Adjustments that a mask applies locally. All -100...100 except where noted.
struct LocalAdjust: Codable, Equatable {
    var exposure: Double = 0       // -4...4 EV
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 0
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var sharpness: Double = 0

    var isNeutral: Bool { self == LocalAdjust() }
}

struct MaskLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: MaskKind
    var name: String
    var personIndex: Int = 0
    var invert = false
    var opacity: Double = 100
    var visible = true
    var linear: MaskLinearGradient? = nil
    var radial: MaskRadialGradient? = nil
    var objectRect: NormRect? = nil
    /// Brush strokes refine any mask (add or erase). A Brush mask is made only of strokes.
    var strokes: [BrushStroke] = []
    var adjust = LocalAdjust()

    init(kind: MaskKind, name: String? = nil, personIndex: Int = 0) {
        self.kind = kind
        self.name = name ?? kind.title
        self.personIndex = personIndex
        if kind == .linear { linear = MaskLinearGradient() }
        if kind == .radial { radial = MaskRadialGradient() }
    }
}
