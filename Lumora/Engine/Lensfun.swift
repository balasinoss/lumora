import Foundation

/// A lens from the open Lensfun database (https://lensfun.github.io, data CC BY-SA 3.0).
final class LensProfile: Identifiable {
    struct Distortion { var focal: Double; var model: String; var a = 0.0, b = 0.0, c = 0.0, k1 = 0.0, k2 = 0.0 }
    struct TCA { var focal: Double; var model: String; var vr = 1.0, vb = 1.0, cr = 0.0, cb = 0.0, br = 0.0, bb = 0.0, kr = 1.0, kb = 1.0 }
    struct Vignetting { var focal: Double; var aperture: Double; var distance: Double; var k1 = 0.0, k2 = 0.0, k3 = 0.0 }

    let id: String
    var maker: String = ""
    var model: String = ""
    var mounts: [String] = []
    var cropFactor: Double = 1.0
    var distortion: [Distortion] = []
    var tca: [TCA] = []
    var vignetting: [Vignetting] = []

    init(id: String) { self.id = id }
    var displayName: String { model.lowercased().hasPrefix(maker.lowercased()) ? model : "\(maker) \(model)" }
    var hasCorrections: Bool { !distortion.isEmpty || !tca.isEmpty || !vignetting.isEmpty }
}

struct LensfunCamera {
    var maker: String
    var model: String
    var cropFactor: Double
}

/// Loads and searches the Lensfun XML database bundled in the app.
final class LensDatabase {
    static let shared = LensDatabase()

    private(set) var lenses: [LensProfile] = []
    private(set) var cameras: [LensfunCamera] = []
    private var loaded = false
    private let lock = NSLock()

    func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let dir = Bundle.main.url(forResource: "LensfunDB", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "xml" {
            let p = LensfunXMLParser(fileTag: f.deletingPathExtension().lastPathComponent)
            if let parser = XMLParser(contentsOf: f) {
                parser.delegate = p
                parser.parse()
                lenses.append(contentsOf: p.lenses.filter { $0.hasCorrections })
                cameras.append(contentsOf: p.cameras)
            }
        }
        lenses.sort { $0.displayName < $1.displayName }
    }

    func lens(id: String) -> LensProfile? {
        loadIfNeeded()
        return lenses.first { $0.id == id }
    }

    func cameraCropFactor(make: String?, model: String?) -> Double? {
        loadIfNeeded()
        guard let model = model?.lowercased() else { return nil }
        let mk = make?.lowercased() ?? ""
        return cameras.first { $0.model.lowercased() == model && (mk.isEmpty || mk.contains($0.maker.lowercased()) || $0.maker.lowercased().contains(mk)) }?.cropFactor
            ?? cameras.first { $0.model.lowercased() == model }?.cropFactor
    }

    /// Best matching lens for EXIF lens information.
    func match(lensModel: String?, lensMake: String?, cameraMake: String?) -> LensProfile? {
        loadIfNeeded()
        guard let lensModel, !lensModel.isEmpty else { return nil }
        let q = Self.tokens(lensModel)
        let qNums = q.filter { $0.first?.isNumber == true }
        guard !q.isEmpty else { return nil }
        let makerHint = (lensMake ?? cameraMake ?? "").lowercased()
        var best: (LensProfile, Double)? = nil
        for lens in lenses {
            let t = Self.tokens(lens.model)
            let tNums = t.filter { $0.first?.isNumber == true }
            // all numbers (focal lengths / apertures) must agree
            if !qNums.isEmpty && Set(qNums) != Set(tNums).intersection(Set(qNums)) { continue }
            if !qNums.isEmpty && Set(tNums).subtracting(qNums).count > 1 { continue }
            let inter = Set(q).intersection(t).count
            let uni = Set(q).union(t).count
            var score = Double(inter) / Double(max(uni, 1))
            if !makerHint.isEmpty && (makerHint.contains(lens.maker.lowercased()) || lens.maker.lowercased().contains(makerHint)) { score += 0.15 }
            if best == nil || score > best!.1 { best = (lens, score) }
        }
        if let best, best.1 >= 0.45 { return best.0 }
        return nil
    }

    /// Splits "EF50mm f/1.8 STM" into ["ef","50","mm","f","1.8","stm"].
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var curIsNum = false
        func flush() { if !cur.isEmpty { out.append(cur) }; cur = "" }
        for ch in s.lowercased() {
            if ch.isNumber || (ch == "." && curIsNum) {
                if !curIsNum { flush(); curIsNum = true }
                cur.append(ch)
            } else if ch.isLetter {
                if curIsNum { flush(); curIsNum = false }
                cur.append(ch)
            } else {
                flush(); curIsNum = false
            }
        }
        flush()
        return out.filter { $0 != "f" && $0 != "mm" && $0 != "lens" }
    }
}

private final class LensfunXMLParser: NSObject, XMLParserDelegate {
    var lenses: [LensProfile] = []
    var cameras: [LensfunCamera] = []
    let fileTag: String

    private var lens: LensProfile?
    private var camera: LensfunCamera?
    private var text = ""
    private var calibCrop: Double?
    private var counter = 0
    private var skipLangModel = false

    init(fileTag: String) { self.fileTag = fileTag }

    private func d(_ a: [String: String], _ k: String, _ def: Double = 0) -> Double { Double(a[k] ?? "") ?? def }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        switch el {
        case "lens":
            counter += 1
            lens = LensProfile(id: "\(fileTag)#\(counter)")
        case "camera":
            camera = LensfunCamera(maker: "", model: "", cropFactor: 1)
        case "model", "maker":
            skipLangModel = a["lang"] != nil
        case "calibration":
            calibCrop = a["cropfactor"].flatMap(Double.init)
        case "distortion":
            guard let lens else { return }
            var x = LensProfile.Distortion(focal: d(a, "focal"), model: a["model"] ?? "")
            x.a = d(a, "a"); x.b = d(a, "b"); x.c = d(a, "c"); x.k1 = d(a, "k1"); x.k2 = d(a, "k2")
            if let calibCrop, lens.cropFactor == 1.0 { lens.cropFactor = calibCrop }
            lens.distortion.append(x)
        case "tca":
            guard let lens else { return }
            var x = LensProfile.TCA(focal: d(a, "focal"), model: a["model"] ?? "")
            x.vr = d(a, "vr", 1); x.vb = d(a, "vb", 1); x.cr = d(a, "cr"); x.cb = d(a, "cb")
            x.br = d(a, "br"); x.bb = d(a, "bb"); x.kr = d(a, "kr", 1); x.kb = d(a, "kb", 1)
            lens.tca.append(x)
        case "vignetting":
            guard let lens else { return }
            var x = LensProfile.Vignetting(focal: d(a, "focal"), aperture: d(a, "aperture"), distance: d(a, "distance", 1000))
            x.k1 = d(a, "k1"); x.k2 = d(a, "k2"); x.k3 = d(a, "k3")
            lens.vignetting.append(x)
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lens {
            switch el {
            case "maker": if !skipLangModel || lens.maker.isEmpty { if !skipLangModel { lens.maker = t } }
            case "model": if !skipLangModel { lens.model = t }
            case "mount": lens.mounts.append(t)
            case "cropfactor": lens.cropFactor = Double(t) ?? lens.cropFactor
            case "lens": lenses.append(lens); self.lens = nil
            default: break
            }
        } else if camera != nil {
            switch el {
            case "maker": if !skipLangModel { camera!.maker = t }
            case "model": if !skipLangModel { camera!.model = t }
            case "cropfactor": camera!.cropFactor = Double(t) ?? 1
            case "camera": cameras.append(camera!); camera = nil
            default: break
            }
        }
        if el == "calibration" { calibCrop = nil }
        text = ""
    }
}

// MARK: - Coefficients for the GPU kernel

/// Everything the lensCorrect kernel needs for one image.
struct LensCoefficients {
    var dist: (a: Double, b: Double, c: Double, d: Double, e: Double) = (0, 0, 0, 1, 0)
    var tcaR: (v: Double, c: Double, b: Double) = (1, 0, 0)
    var tcaB: (v: Double, c: Double, b: Double) = (1, 0, 0)
    var vig: (k1: Double, k2: Double, k3: Double) = (0, 0, 0)
    /// r_calibration = r_image * cropRatio
    var cropRatio: Double = 1

    var isIdentity: Bool {
        dist == (0, 0, 0, 1, 0) && tcaR == (1, 0, 0) && tcaB == (1, 0, 0) && vig == (0, 0, 0)
    }

    static func make(profile: LensProfile, focal: Double, aperture: Double, imageCrop: Double?,
                     useDistortion: Bool, distortionAmount: Double, useTCA: Bool,
                     useVignetting: Bool, vignetteAmount: Double) -> LensCoefficients {
        var co = LensCoefficients()
        if let imageCrop, imageCrop > 0 { co.cropRatio = profile.cropFactor / imageCrop }

        func bracket<T>(_ items: [T], _ f: (T) -> Double) -> (T, T, Double)? {
            guard !items.isEmpty else { return nil }
            let sorted = items.sorted { f($0) < f($1) }
            if focal <= f(sorted.first!) { return (sorted.first!, sorted.first!, 0) }
            if focal >= f(sorted.last!) { return (sorted.last!, sorted.last!, 0) }
            for i in 0..<(sorted.count - 1) where focal >= f(sorted[i]) && focal <= f(sorted[i + 1]) {
                let span = f(sorted[i + 1]) - f(sorted[i])
                return (sorted[i], sorted[i + 1], span > 0 ? (focal - f(sorted[i])) / span : 0)
            }
            return (sorted.last!, sorted.last!, 0)
        }
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

        if useDistortion, let (d0, d1, t) = bracket(profile.distortion, { $0.focal }) {
            func coeffs(_ d: LensProfile.Distortion) -> (Double, Double, Double, Double, Double) {
                switch d.model {
                case "ptlens": return (d.a, d.b, d.c, 1 - d.a - d.b - d.c, 0)
                case "poly3": return (0, d.k1, 0, 1 - d.k1, 0)
                case "poly5": return (0, d.k1, 0, 1, d.k2)
                default: return (0, 0, 0, 1, 0)
                }
            }
            let x0 = coeffs(d0), x1 = coeffs(d1)
            let k = distortionAmount / 100
            // blend toward identity with the amount slider
            co.dist = (lerp(x0.0, x1.0, t) * k, lerp(x0.1, x1.1, t) * k, lerp(x0.2, x1.2, t) * k,
                       1 + (lerp(x0.3, x1.3, t) - 1) * k, lerp(x0.4, x1.4, t) * k)
        }
        if useTCA, let (t0, t1, t) = bracket(profile.tca, { $0.focal }) {
            func r(_ x: LensProfile.TCA) -> (Double, Double, Double) { x.model == "linear" ? (x.kr, 0, 0) : (x.vr, x.cr, x.br) }
            func b(_ x: LensProfile.TCA) -> (Double, Double, Double) { x.model == "linear" ? (x.kb, 0, 0) : (x.vb, x.cb, x.bb) }
            let r0 = r(t0), r1 = r(t1), b0 = b(t0), b1 = b(t1)
            co.tcaR = (lerp(r0.0, r1.0, t), lerp(r0.1, r1.1, t), lerp(r0.2, r1.2, t))
            co.tcaB = (lerp(b0.0, b1.0, t), lerp(b0.1, b1.1, t), lerp(b0.2, b1.2, t))
        }
        if useVignetting, !profile.vignetting.isEmpty {
            // nearest focal, then nearest aperture, farthest distance
            let nearestFocal = profile.vignetting.min { abs($0.focal - focal) < abs($1.focal - focal) }!.focal
            let atFocal = profile.vignetting.filter { $0.focal == nearestFocal }
            let ap = aperture > 0 ? aperture : atFocal.map(\.aperture).min() ?? 0
            let nearestAp = atFocal.min { abs(log($0.aperture / max(ap, 0.5))) < abs(log($1.aperture / max(ap, 0.5))) }!.aperture
            let v = atFocal.filter { $0.aperture == nearestAp }.max { $0.distance < $1.distance }!
            let k = vignetteAmount / 100
            co.vig = (v.k1 * k, v.k2 * k, v.k3 * k)
        }
        return co
    }
}
