import Foundation

/// A value a preset sets. Numbers blend with the preset Amount; everything else switches at 50%.
enum PatchValue: Codable, Equatable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case points([[Double]])
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var category: String
    /// key paths into EditSettings' JSON, e.g. "exposure", "mixer.3.hue", "gradeShadows.saturation", "curveMaster"
    var values: [String: PatchValue]
    var builtIn = false
    var created = Date()
}

/// Stores presets in Documents/Presets/*.json. Imports Lightroom .lrtemplate / .xmp presets.
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    @Published private(set) var presets: [Preset] = []

    private let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { reload() }

    var categories: [String] {
        var seen: [String] = []
        for p in presets where !seen.contains(p.category) { seen.append(p.category) }
        return seen
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var list = files.compactMap { u -> Preset? in
            guard u.pathExtension == "json", let d = try? Data(contentsOf: u) else { return nil }
            return try? JSONDecoder().decode(Preset.self, from: d)
        }
        list.sort { ($0.category, $0.name) < ($1.category, $1.name) }
        presets = PresetStore.builtIns + list
    }

    func save(_ p: Preset) {
        guard !p.builtIn, let d = try? JSONEncoder().encode(p) else { return }
        try? d.write(to: dir.appendingPathComponent(p.id.uuidString + ".json"), options: .atomic)
        reload()
    }
    func delete(_ p: Preset) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(p.id.uuidString + ".json"))
        reload()
    }

    // MARK: Apply

    /// Applies a preset with an amount (0...2). `base` is the photo's settings before the preset.
    static func apply(_ preset: Preset, amount: Double, to base: EditSettings) -> EditSettings {
        guard let data = try? JSONEncoder().encode(base),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return base }
        for (path, v) in preset.values {
            let parts = path.split(separator: ".").map(String.init)
            switch v {
            case .number(let x):
                let cur = (getValue(root, parts) as? NSNumber)?.doubleValue ?? 0
                setValue(&root, parts, cur + (x - cur) * amount)
            case .bool(let b): if amount >= 0.5 { setValue(&root, parts, b) }
            case .string(let s): if amount >= 0.5 { setValue(&root, parts, s) }
            case .points(let pts):
                if amount > 0 { setValue(&root, parts, pts.map { ["x": $0[0], "y": $0[1]] }) }
            }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: root) else { return base }
        return EditSettings.decode(out) ?? base
    }

    private static func getValue(_ root: Any, _ path: [String]) -> Any? {
        var cur: Any? = root
        for p in path {
            if let d = cur as? [String: Any] { cur = d[p] }
            else if let a = cur as? [Any], let i = Int(p), i < a.count { cur = a[i] }
            else { return nil }
        }
        return cur
    }

    private static func setValue(_ node: inout [String: Any], _ path: [String], _ value: Any) {
        guard let first = path.first else { return }
        if path.count == 1 { node[first] = value; return }
        let rest = Array(path.dropFirst())
        if var child = node[first] as? [String: Any] {
            setValue(&child, rest, value); node[first] = child
        } else if var arr = node[first] as? [Any], let i = Int(rest[0]), i < arr.count {
            if rest.count == 1 { arr[i] = value }
            else if var c = arr[i] as? [String: Any] { setValue(&c, Array(rest.dropFirst()), value); arr[i] = c }
            node[first] = arr
        } else {
            var child: [String: Any] = [:]
            setValue(&child, rest, value); node[first] = child
        }
    }

    // MARK: Make a preset from the current photo

    /// Keys that belong to one photo and never go into presets.
    static let perPhotoKeys: Set<String> = ["crop", "cropAspect", "straighten", "rotation90", "flipH", "flipV", "masks",
                                            "lensProfileID", "aiDenoise", "aiDenoiseAmount", "healSpots", "pointColors",
                                            "vertical", "horizontal", "rotate", "aspect", "scale", "offsetX", "offsetY",
                                            "temperature", "profile", "profileAmount"]

    static func fromSettings(_ s: EditSettings, name: String, category: String, groups: Set<String>? = nil) -> Preset {
        var values: [String: PatchValue] = [:]
        guard let data = try? JSONEncoder().encode(s),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Preset(name: name, category: category, values: [:])
        }
        func walk(_ node: Any, _ path: [String]) {
            if let d = node as? [String: Any] {
                for (k, v) in d { walk(v, path + [k]) }
            } else if let a = node as? [Any] {
                if let pts = a as? [[String: Any]], pts.first?["x"] != nil {
                    values[path.joined(separator: ".")] = .points(pts.map { [($0["x"] as? NSNumber)?.doubleValue ?? 0, ($0["y"] as? NSNumber)?.doubleValue ?? 0] })
                } else {
                    for (i, v) in a.enumerated() { walk(v, path + [String(i)]) }
                }
            } else if let n = node as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { values[path.joined(separator: ".")] = .bool(n.boolValue) }
                else { values[path.joined(separator: ".")] = .number(n.doubleValue) }
            } else if let str = node as? String {
                values[path.joined(separator: ".")] = .string(str)
            }
        }
        for (k, v) in root where !perPhotoKeys.contains(k) { walk(v, [k]) }
        return Preset(name: name, category: category, values: values)
    }

    // MARK: Built-in looks (Lumora's own)

    static let builtIns: [Preset] = {
        func p(_ name: String, _ v: [String: PatchValue]) -> Preset {
            // stable id from the name (FNV-1a)
            var h: UInt64 = 0xcbf29ce484222325
            for c in name.utf8 { h = (h ^ UInt64(c)) &* 0x100000001b3 }
            let hex = String(format: "%012llx", h & 0xFFFFFFFFFFFF)
            return Preset(id: UUID(uuidString: "00000000-0000-4000-8000-" + hex) ?? UUID(),
                          name: name, category: "Lumora", values: v, builtIn: true)
        }
        return [
            p("Courtside Pop", ["contrast": .number(18), "clarity": .number(12), "vibrance": .number(22), "highlights": .number(-25), "shadows": .number(20), "sharpening": .number(50)]),
            p("Gym Fix", ["whiteBalance": .string("Auto"), "highlights": .number(-35), "shadows": .number(25), "dehaze": .number(8), "mixer.1.saturation": .number(-15), "mixer.2.saturation": .number(-30), "mixer.3.saturation": .number(-20)]),
            p("Gritty", ["contrast": .number(30), "clarity": .number(35), "texture": .number(20), "saturation": .number(-25), "vignette": .number(-20), "grain": .number(12)]),
            p("Clean Bright", ["exposure": .number(0.3), "contrast": .number(-5), "highlights": .number(-30), "shadows": .number(35), "whites": .number(15), "vibrance": .number(15)]),
            p("Cinematic", ["contrast": .number(12), "highlights": .number(-20), "saturation": .number(-8), "gradeShadows.hue": .number(190), "gradeShadows.saturation": .number(28), "gradeHighlights.hue": .number(32), "gradeHighlights.saturation": .number(25)]),
            p("Matte Film", ["contrast": .number(-15), "saturation": .number(-12), "grain": .number(15), "curveMaster": .points([[0, 0.09], [0.5, 0.5], [1, 0.95]])]),
            p("Mono Punch", ["blackAndWhite": .bool(true), "contrast": .number(30), "clarity": .number(15), "bwMix.5": .number(-25), "bwMix.0": .number(10)]),
            p("Mono Soft", ["blackAndWhite": .bool(true), "contrast": .number(-20), "shadows": .number(15)]),
        ]
    }()
}

// MARK: - Lightroom preset import

enum LightroomImport {
    enum ImportError: LocalizedError {
        case unreadable, noSettings
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This file isn't a Lightroom preset."
            case .noSettings: return "No develop settings found in this preset."
            }
        }
    }

    /// Reads a .lrtemplate or .xmp preset. Returns (title, group, LR settings dictionary).
    static func read(_ url: URL) throws -> (String, String?, [String: Any]) {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            throw ImportError.unreadable
        }
        let fileTitle = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "xmp" || text.contains("<x:xmpmeta") {
            return try readXMP(text, fallbackTitle: fileTitle)
        }
        var parser = LuaTableParser(text)
        guard let root = parser.parseRoot() as? [String: Any] else { throw ImportError.unreadable }
        let value = root["value"] as? [String: Any]
        guard let settings = value?["settings"] as? [String: Any] else { throw ImportError.noSettings }
        let title = (root["title"] as? String) ?? (root["internalName"] as? String) ?? fileTitle
        return (title, nil, settings)
    }

    private static func readXMP(_ text: String, fallbackTitle: String) throws -> (String, String?, [String: Any]) {
        var settings: [String: Any] = [:]
        let ns = text as NSString
        // attributes: crs:Name="value"
        let attr = try! NSRegularExpression(pattern: "crs:([A-Za-z0-9]+)=\"([^\"]*)\"")
        for m in attr.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1)), v = ns.substring(with: m.range(at: 2))
            settings[k] = parseScalar(v)
        }
        // element form: <crs:Name>value</crs:Name>
        let elem = try! NSRegularExpression(pattern: "<crs:([A-Za-z0-9]+)>([^<]+)</crs:\\1>")
        for m in elem.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1)), v = ns.substring(with: m.range(at: 2))
            if settings[k] == nil { settings[k] = parseScalar(v) }
        }
        // sequences (tone curves): <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li>...
        let seq = try! NSRegularExpression(pattern: "<crs:(ToneCurve[A-Za-z0-9]*)>\\s*<rdf:Seq>(.*?)</rdf:Seq>", options: [.dotMatchesLineSeparators])
        let li = try! NSRegularExpression(pattern: "<rdf:li>([^<]*)</rdf:li>")
        for m in seq.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2)) as NSString
            var nums: [Double] = []
            for l in li.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                for part in body.substring(with: l.range(at: 1)).split(separator: ",") {
                    if let d = Double(part.trimmingCharacters(in: .whitespaces)) { nums.append(d) }
                }
            }
            settings[k] = nums
        }
        func alt(_ tag: String) -> String? {
            let r = try! NSRegularExpression(pattern: "<crs:\(tag)>\\s*<rdf:Alt>\\s*<rdf:li[^>]*>([^<]*)</rdf:li>", options: [.dotMatchesLineSeparators])
            guard let m = r.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
        guard !settings.isEmpty else { throw ImportError.noSettings }
        let title = alt("Name") ?? (settings["Name"] as? String) ?? fallbackTitle
        return (title, alt("Group") ?? (settings["Group"] as? String), settings)
    }

    private static func parseScalar(_ s: String) -> Any {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t == "True" || t == "true" { return true }
        if t == "False" || t == "false" { return false }
        if let d = Double(t.hasPrefix("+") ? String(t.dropFirst()) : t) { return d }
        return t
    }

    /// Splits "Presetpro - Bronze Shadow" into ("Presetpro", "Bronze Shadow").
    static func splitTitle(_ title: String, group: String?) -> (String, String) {
        if let g = group, !g.isEmpty {
            return (g, title.hasPrefix(g + " - ") ? String(title.dropFirst(g.count + 3)) : title)
        }
        for sep in [" - ", " – ", " — ", " | ", ": "] {
            if let r = title.range(of: sep) {
                let cat = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let name = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !cat.isEmpty && !name.isEmpty { return (cat, name) }
            }
        }
        return ("Imported", title)
    }

    // MARK: Mapping Lightroom settings -> Lumora key paths

    static let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]

    static func convert(_ lr: [String: Any]) -> [String: PatchValue] {
        var v: [String: PatchValue] = [:]
        func num(_ k: String) -> Double? {
            if let d = lr[k] as? Double { return d }
            if let n = lr[k] as? NSNumber { return n.doubleValue }
            if let s = lr[k] as? String { return Double(s.hasPrefix("+") ? String(s.dropFirst()) : s) }
            return nil
        }
        func bool(_ k: String) -> Bool? {
            if let b = lr[k] as? Bool { return b }
            if let d = num(k) { return d != 0 }
            return nil
        }
        func map(_ lrKey: String, _ key: String, scale: Double = 1) {
            if let d = num(lrKey) { v[key] = .number(d * scale) }
        }

        // Light
        map("Exposure2012", "exposure"); map("Exposure", "exposure")
        map("Contrast2012", "contrast"); map("Highlights2012", "highlights"); map("Shadows2012", "shadows")
        map("Whites2012", "whites"); map("Blacks2012", "blacks")
        // Presence
        map("Texture", "texture"); map("Clarity2012", "clarity"); map("Dehaze", "dehaze")
        map("Vibrance", "vibrance"); map("Saturation", "saturation")
        // White balance
        if let wb = lr["WhiteBalance"] as? String {
            switch wb {
            case "As Shot", "Auto", "Daylight", "Cloudy", "Shade", "Tungsten", "Fluorescent", "Flash": v["whiteBalance"] = .string(wb)
            default: v["whiteBalance"] = .string("Custom")
            }
        }
        if let t = num("IncrementalTemperature") { v["tempShift"] = .number(t); v["whiteBalance"] = .string("Custom") }
        if let t = num("IncrementalTint") { v["tint"] = .number(t); v["whiteBalance"] = .string("Custom") }
        if let t = num("Temperature") { v["temperature"] = .number(t); v["whiteBalance"] = .string("Custom") }
        if let t = num("Tint") { v["tint"] = .number(t) }
        // Colour mixer
        for (i, b) in bands.enumerated() {
            map("HueAdjustment\(b)", "mixer.\(i).hue")
            map("SaturationAdjustment\(b)", "mixer.\(i).saturation")
            map("LuminanceAdjustment\(b)", "mixer.\(i).luminance")
            map("GrayMixer\(b)", "bwMix.\(i)")
        }
        if let g = bool("ConvertToGrayscale") { v["blackAndWhite"] = .bool(g) }
        // Split toning / colour grading
        map("SplitToningShadowHue", "gradeShadows.hue"); map("SplitToningShadowSaturation", "gradeShadows.saturation")
        map("SplitToningHighlightHue", "gradeHighlights.hue"); map("SplitToningHighlightSaturation", "gradeHighlights.saturation")
        map("SplitToningBalance", "gradeBalance")
        map("ColorGradeShadowLum", "gradeShadows.luminance"); map("ColorGradeHighlightLum", "gradeHighlights.luminance")
        map("ColorGradeMidtoneHue", "gradeMidtones.hue"); map("ColorGradeMidtoneSat", "gradeMidtones.saturation"); map("ColorGradeMidtoneLum", "gradeMidtones.luminance")
        map("ColorGradeGlobalHue", "gradeGlobal.hue"); map("ColorGradeGlobalSat", "gradeGlobal.saturation"); map("ColorGradeGlobalLum", "gradeGlobal.luminance")
        map("ColorGradeBlending", "gradeBlending")
        // Detail
        map("Sharpness", "sharpening"); map("SharpenRadius", "sharpenRadius"); map("SharpenDetail", "sharpenDetail"); map("SharpenEdgeMasking", "sharpenMasking")
        map("LuminanceSmoothing", "noiseReduction"); map("LuminanceNoiseReductionDetail", "noiseDetail"); map("LuminanceNoiseReductionContrast", "noiseContrast")
        map("ColorNoiseReduction", "colorNoiseReduction"); map("ColorNoiseReductionDetail", "colorNoiseDetail"); map("ColorNoiseReductionSmoothness", "colorNoiseSmoothness")
        // Effects
        map("GrainAmount", "grain"); map("GrainSize", "grainSize"); map("GrainFrequency", "grainRoughness")
        map("PostCropVignetteAmount", "vignette"); map("PostCropVignetteMidpoint", "vignetteMidpoint")
        map("PostCropVignetteRoundness", "vignetteRoundness"); map("PostCropVignetteFeather", "vignetteFeather")
        map("PostCropVignetteHighlightContrast", "vignetteHighlights")
        // Optics
        if let b = bool("AutoLateralCA") { v["removeChromaticAberration"] = .bool(b) }
        if let b = bool("LensProfileEnable") { v["enableLensCorrection"] = .bool(b) }
        map("LensManualDistortionAmount", "manualDistortion"); map("VignetteAmount", "manualVignette"); map("VignetteMidpoint", "manualVignetteMidpoint")
        map("DefringePurpleAmount", "defringePurple"); map("DefringePurpleHueLo", "purpleHueLow"); map("DefringePurpleHueHi", "purpleHueHigh")
        map("DefringeGreenAmount", "defringeGreen"); map("DefringeGreenHueLo", "greenHueLow"); map("DefringeGreenHueHi", "greenHueHigh")
        // Calibration
        map("RedHue", "calRedHue"); map("RedSaturation", "calRedSat")
        map("GreenHue", "calGreenHue"); map("GreenSaturation", "calGreenSat")
        map("BlueHue", "calBlueHue"); map("BlueSaturation", "calBlueSat")
        map("ShadowTint", "calShadowTint")

        // Tone curves (point lists of x,y pairs in 0...255), combined with the parametric curve
        func points(_ k: String) -> [[Double]]? {
            guard let raw = lr[k] as? [Any] else { return nil }
            let nums = raw.compactMap { ($0 as? Double) ?? ($0 as? NSNumber)?.doubleValue }
            guard nums.count >= 4 else { return nil }
            var pts: [[Double]] = []
            var i = 0
            while i + 1 < nums.count { pts.append([nums[i] / 255, nums[i + 1] / 255]); i += 2 }
            return pts.sorted { $0[0] < $1[0] }
        }
        let parametric = [num("ParametricShadows") ?? 0, num("ParametricDarks") ?? 0, num("ParametricLights") ?? 0, num("ParametricHighlights") ?? 0]
        let splits = [(num("ParametricShadowSplit") ?? 25) / 100, (num("ParametricMidtoneSplit") ?? 50) / 100, (num("ParametricHighlightSplit") ?? 75) / 100]
        let master = points("ToneCurvePV2012") ?? points("ToneCurve")
        if parametric.contains(where: { $0 != 0 }) || master != nil {
            let mPts = (master ?? [[0, 0], [1, 1]]).map { CurvePoint(x: $0[0], y: $0[1]) }
            var combined: [[Double]] = []
            for i in 0...12 {
                let x = Double(i) / 12
                let px = parametricCurve(x, parametric, splits)
                combined.append([x, Curves.evaluate(mPts, px)])
            }
            // keep the curve simple when there's no parametric part
            v["curveMaster"] = .points(parametric.contains(where: { $0 != 0 }) ? combined : (master ?? []))
        }
        if let r = points("ToneCurvePV2012Red") { v["curveRed"] = .points(r) }
        if let g = points("ToneCurvePV2012Green") { v["curveGreen"] = .points(g) }
        if let b = points("ToneCurvePV2012Blue") { v["curveBlue"] = .points(b) }
        return v
    }

    /// Approximation of Lightroom's parametric (region) curve.
    static func parametricCurve(_ x: Double, _ adj: [Double], _ splits: [Double]) -> Double {
        let edges = [0.0, splits[0], splits[1], splits[2], 1.0]
        var y = x
        for k in 0..<4 where adj[k] != 0 {
            let a = edges[k], b = edges[k + 1]
            let c = (a + b) / 2, half = max((b - a) / 2, 0.05) * 1.6
            let t = max(0, 1 - abs(x - c) / half)
            let bump = t * t * (3 - 2 * t)
            y += adj[k] / 100 * 0.22 * bump * min(x, 1 - x) * 2.2
        }
        return min(max(y, 0), 1)
    }
}

/// Minimal parser for the Lua table syntax used by .lrtemplate files.
struct LuaTableParser {
    private let b: [UInt8]
    private var i = 0
    init(_ text: String) { b = Array(text.utf8) }

    mutating func parseRoot() -> Any? {
        // skip "s =" prefix
        while i < b.count && b[i] != UInt8(ascii: "{") { i += 1 }
        return parseValue()
    }

    private mutating func skip() {
        while i < b.count {
            let c = b[i]
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
            if c == UInt8(ascii: "-") && i + 1 < b.count && b[i + 1] == UInt8(ascii: "-") {
                while i < b.count && b[i] != 10 { i += 1 }
                continue
            }
            break
        }
    }

    private mutating func parseValue() -> Any? {
        skip()
        guard i < b.count else { return nil }
        let c = b[i]
        if c == UInt8(ascii: "{") { return parseTable() }
        if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { return parseString(c) }
        if c == UInt8(ascii: "[") && i + 1 < b.count && b[i + 1] == UInt8(ascii: "[") { return parseLongString() }
        if matchWord("true") { return true }
        if matchWord("false") { return false }
        if matchWord("nil") { return NSNull() }
        return parseNumber()
    }

    private mutating func matchWord(_ w: String) -> Bool {
        let u = Array(w.utf8)
        guard i + u.count <= b.count, Array(b[i..<(i + u.count)]) == u else { return false }
        if i + u.count < b.count, isIdent(b[i + u.count]) { return false }
        i += u.count
        return true
    }

    private func isIdent(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
    }

    private mutating func parseNumber() -> Any? {
        let start = i
        while i < b.count {
            let ch = b[i]
            let ok = (ch >= 48 && ch <= 57) || ch == 45 || ch == 43 || ch == 46 || ch == 101 || ch == 69
            if !ok { break }
            i += 1
        }
        if i == start { i += 1; return nil }
        return Double(String(decoding: b[start..<i], as: UTF8.self))
    }

    private mutating func parseString(_ q: UInt8) -> String {
        i += 1
        var out: [UInt8] = []
        while i < b.count && b[i] != q {
            if b[i] == 92 && i + 1 < b.count {      // backslash
                i += 1
                switch b[i] {
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "t"): out.append(9)
                default: out.append(b[i])
                }
            } else { out.append(b[i]) }
            i += 1
        }
        i += 1
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func parseLongString() -> String {
        i += 2
        let start = i
        while i + 1 < b.count && !(b[i] == UInt8(ascii: "]") && b[i + 1] == UInt8(ascii: "]")) { i += 1 }
        let s = String(decoding: b[start..<min(i, b.count)], as: UTF8.self)
        i += 2
        return s
    }

    private mutating func parseTable() -> Any {
        i += 1
        var dict: [String: Any] = [:]
        var arr: [Any] = []
        while true {
            skip()
            guard i < b.count else { break }
            if b[i] == UInt8(ascii: "}") { i += 1; break }
            if b[i] == UInt8(ascii: ",") || b[i] == UInt8(ascii: ";") { i += 1; continue }
            // key = value ?
            var key: String?
            if b[i] == UInt8(ascii: "[") && !(i + 1 < b.count && b[i + 1] == UInt8(ascii: "[")) {
                i += 1
                let k = parseValue()
                skip(); if i < b.count && b[i] == UInt8(ascii: "]") { i += 1 }
                skip(); if i < b.count && b[i] == UInt8(ascii: "=") { i += 1 }
                key = k.map { "\($0)" }
            } else if isIdent(b[i]) && !(b[i] >= 48 && b[i] <= 57) {
                let save = i
                while i < b.count && isIdent(b[i]) { i += 1 }
                let ident = String(decoding: b[save..<i], as: UTF8.self)
                skip()
                if i < b.count && b[i] == UInt8(ascii: "=") { i += 1; key = ident } else { i = save }
            }
            let val = parseValue() ?? NSNull()
            if let key { dict[key] = val } else { arr.append(val) }
        }
        return dict.isEmpty && !arr.isEmpty ? arr : (dict.isEmpty ? [String: Any]() : dict)
    }
}
