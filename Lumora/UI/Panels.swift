import SwiftUI

extension EditorModel {
    func b(_ kp: WritableKeyPath<EditSettings, Double>) -> Binding<Double> {
        Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 })
    }
    func bool(_ kp: WritableKeyPath<EditSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.settings[keyPath: kp] }, set: { v in self.edit { $0[keyPath: kp] = v } })
    }
}

/// Scrollable container used by every panel.
struct PanelScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { VStack(spacing: 2) { content }.padding(.horizontal, 18).padding(.vertical, 10) }
    }
}

// MARK: - Looks

struct ProfilesPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        PanelScroll {
            SectionTitle(text: "Look")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(Profiles.all, id: \.self) { p in
                    Chip(title: p, selected: model.settings.profile == p) { model.edit { $0.profile = p } }
                }
            }
            if model.settings.profile != "Color" {
                LSlider(label: "Amount", value: model.b(\.profileAmount), range: 0...200, defaultValue: 100, format: { "\(Int($0))" }, onCommit: model.commit)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Light

struct LightPanel: View {
    @ObservedObject var model: EditorModel
    @State private var showCurve = false
    var body: some View {
        PanelScroll {
            HStack {
                Picker("", selection: $showCurve) { Text("Sliders").tag(false); Text("Curve").tag(true) }
                    .pickerStyle(.segmented).frame(width: 180)
                Spacer()
                Button("Auto") { model.autoTone() }.buttonStyle(.bordered)
            }
            if showCurve {
                CurveEditor(model: model)
            } else {
                LSlider(label: "Exposure", value: model.b(\.exposure), range: -5...5, step: 0.01,
                        format: { String(format: "%+.2f", $0) }, onCommit: model.commit)
                LSlider(label: "Contrast", value: model.b(\.contrast), onCommit: model.commit)
                LSlider(label: "Highlights", value: model.b(\.highlights), onCommit: model.commit)
                LSlider(label: "Shadows", value: model.b(\.shadows), onCommit: model.commit)
                LSlider(label: "Whites", value: model.b(\.whites), onCommit: model.commit)
                LSlider(label: "Blacks", value: model.b(\.blacks), onCommit: model.commit)
            }
        }
    }
}

// MARK: - Color

struct ColorPanel: View {
    @ObservedObject var model: EditorModel
    @State private var page = 0
    @State private var band: ColorBand = .red
    @State private var range = 0

    var isRAW: Bool { model.item.isRAW }

    var body: some View {
        PanelScroll {
            Picker("", selection: $page) {
                Text("Basic").tag(0); Text("Mix").tag(1); Text("Grading").tag(2)
            }.pickerStyle(.segmented)
            switch page {
            case 1: mixer
            case 2: grading
            default: basic
            }
        }
    }

    var wbOptions: [String] {
        isRAW ? ["As Shot", "Auto", "Daylight", "Cloudy", "Shade", "Tungsten", "Fluorescent", "Flash", "Custom"] : ["As Shot", "Auto", "Custom"]
    }

    var tempBinding: Binding<Double> {
        if isRAW {
            return Binding(get: {
                let (t, _) = model.source?.rawWhiteBalance(model.settings) ?? (5500, 0)
                return t
            }, set: { v in
                if model.settings.whiteBalance != "Custom" {
                    let (_, ti) = model.source?.rawWhiteBalance(model.settings) ?? (5500, 0)
                    model.settings.tint = ti
                }
                model.settings.whiteBalance = "Custom"; model.settings.temperature = v
            })
        }
        return Binding(get: { model.settings.tempShift }, set: { model.settings.tempShift = $0; model.settings.whiteBalance = "Custom" })
    }
    var tintBinding: Binding<Double> {
        if isRAW {
            return Binding(get: {
                let (_, ti) = model.source?.rawWhiteBalance(model.settings) ?? (5500, 0)
                return ti
            }, set: { v in
                if model.settings.whiteBalance != "Custom" {
                    let (t, _) = model.source?.rawWhiteBalance(model.settings) ?? (5500, 0)
                    model.settings.temperature = t
                }
                model.settings.whiteBalance = "Custom"; model.settings.tint = v
            })
        }
        return Binding(get: { model.settings.tint }, set: { model.settings.tint = $0; model.settings.whiteBalance = "Custom" })
    }

    @ViewBuilder var basic: some View {
        HStack {
            Text("White Balance").font(.system(size: 13)).foregroundStyle(Theme.text2)
            Spacer()
            Menu(model.settings.whiteBalance) {
                ForEach(wbOptions, id: \.self) { o in
                    Button(o) { model.edit { $0.whiteBalance = o; if o != "Custom" { $0.temperature = nil; if !isRAW { $0.tempShift = 0; $0.tint = 0 } else { $0.tint = 0 } } } }
                }
            }
        }.padding(.top, 6)
        if isRAW {
            LSlider(label: "Temp", value: tempBinding, range: 2000...12000, defaultValue: model.source?.asShotTemperature ?? 5500, step: 50,
                    gradient: Tracks.temp, format: { "\(Int($0)) K" }, onCommit: model.commit)
            LSlider(label: "Tint", value: tintBinding, range: -150...150, defaultValue: model.source?.asShotTint ?? 0, gradient: Tracks.tint, onCommit: model.commit)
        } else {
            LSlider(label: "Temp", value: tempBinding, gradient: Tracks.temp, onCommit: model.commit)
            LSlider(label: "Tint", value: tintBinding, gradient: Tracks.tint, onCommit: model.commit)
        }
        LSlider(label: "Vibrance", value: model.b(\.vibrance), onCommit: model.commit)
        LSlider(label: "Saturation", value: model.b(\.saturation), onCommit: model.commit)
        Toggle("Black & White", isOn: model.bool(\.blackAndWhite)).font(.system(size: 13)).padding(.top, 4)
    }

    func mixBinding(_ kp: WritableKeyPath<HSLBand, Double>) -> Binding<Double> {
        Binding(get: { model.settings.mixer[band.rawValue][keyPath: kp] },
                set: { model.settings.mixer[band.rawValue][keyPath: kp] = $0 })
    }
    var bwBinding: Binding<Double> {
        Binding(get: { model.settings.bwMix[band.rawValue] }, set: { model.settings.bwMix[band.rawValue] = $0 })
    }

    @ViewBuilder var mixer: some View {
        HStack(spacing: 10) {
            ForEach(ColorBand.allCases) { c in
                Circle().fill(Color(hue: c.hue / 360, saturation: 0.85, brightness: 0.95))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white, lineWidth: band == c ? 2.5 : 0).padding(-3))
                    .onTapGesture { band = c }
            }
        }.padding(.vertical, 10)
        if model.settings.blackAndWhite {
            LSlider(label: "\(band.name) (B&W)", value: bwBinding, gradient: Tracks.lum(for: band), onCommit: model.commit)
        } else {
            LSlider(label: "Hue", value: mixBinding(\.hue), gradient: Tracks.hue(for: band), onCommit: model.commit)
            LSlider(label: "Saturation", value: mixBinding(\.saturation), gradient: Tracks.sat(for: band), onCommit: model.commit)
            LSlider(label: "Luminance", value: mixBinding(\.luminance), gradient: Tracks.lum(for: band), onCommit: model.commit)
        }
        Button("Reset Mix") { model.edit { $0.mixer = Array(repeating: HSLBand(), count: 8); $0.bwMix = Array(repeating: 0, count: 8) } }
            .font(.footnote).padding(.top, 4)
    }

    var wheelKP: WritableKeyPath<EditSettings, GradeWheel> {
        [\EditSettings.gradeShadows, \EditSettings.gradeMidtones, \EditSettings.gradeHighlights, \EditSettings.gradeGlobal][range]
    }
    func wheel(_ kp: WritableKeyPath<GradeWheel, Double>) -> Binding<Double> {
        let w = wheelKP
        return Binding(get: { model.settings[keyPath: w][keyPath: kp] }, set: { model.settings[keyPath: w][keyPath: kp] = $0 })
    }

    @ViewBuilder var grading: some View {
        Picker("", selection: $range) {
            Text("Shadows").tag(0); Text("Midtones").tag(1); Text("Highlights").tag(2); Text("Global").tag(3)
        }.pickerStyle(.segmented).padding(.top, 6)
        HStack(alignment: .center, spacing: 16) {
            ColorWheel(hue: wheel(\.hue), saturation: wheel(\.saturation), onCommit: model.commit)
                .frame(width: 120, height: 120)
            VStack {
                LSlider(label: "Hue", value: wheel(\.hue), range: 0...360, defaultValue: 0, format: { "\(Int($0))°" }, onCommit: model.commit)
                LSlider(label: "Sat", value: wheel(\.saturation), range: 0...100, defaultValue: 0, format: { "\(Int($0))" }, onCommit: model.commit)
            }
        }.padding(.vertical, 6)
        LSlider(label: "Luminance", value: wheel(\.luminance), onCommit: model.commit)
        LSlider(label: "Blending", value: model.b(\.gradeBlending), range: 0...100, defaultValue: 50, format: { "\(Int($0))" }, onCommit: model.commit)
        LSlider(label: "Balance", value: model.b(\.gradeBalance), onCommit: model.commit)
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        PanelScroll {
            LSlider(label: "Texture", value: model.b(\.texture), onCommit: model.commit)
            LSlider(label: "Clarity", value: model.b(\.clarity), onCommit: model.commit)
            LSlider(label: "Dehaze", value: model.b(\.dehaze), onCommit: model.commit)
            SectionTitle(text: "Vignette")
            LSlider(label: "Amount", value: model.b(\.vignette), onCommit: model.commit)
            if model.settings.vignette != 0 {
                LSlider(label: "Midpoint", value: model.b(\.vignetteMidpoint), range: 0...100, defaultValue: 50, format: { "\(Int($0))" }, onCommit: model.commit)
                LSlider(label: "Roundness", value: model.b(\.vignetteRoundness), onCommit: model.commit)
                LSlider(label: "Feather", value: model.b(\.vignetteFeather), range: 0...100, defaultValue: 50, format: { "\(Int($0))" }, onCommit: model.commit)
                LSlider(label: "Highlights", value: model.b(\.vignetteHighlights), range: 0...100, defaultValue: 0, format: { "\(Int($0))" }, onCommit: model.commit)
            }
            SectionTitle(text: "Grain")
            LSlider(label: "Amount", value: model.b(\.grain), range: 0...100, defaultValue: 0, format: { "\(Int($0))" }, onCommit: model.commit)
            if model.settings.grain > 0 {
                LSlider(label: "Size", value: model.b(\.grainSize), range: 0...100, defaultValue: 25, format: { "\(Int($0))" }, onCommit: model.commit)
                LSlider(label: "Roughness", value: model.b(\.grainRoughness), range: 0...100, defaultValue: 50, format: { "\(Int($0))" }, onCommit: model.commit)
            }
        }
    }
}

// MARK: - Detail

struct DetailPanel: View {
    @ObservedObject var model: EditorModel
    func n(_ v: Double) -> String { "\(Int(v.rounded()))" }
    var body: some View {
        PanelScroll {
            SectionTitle(text: "Sharpening")
            LSlider(label: "Amount", value: model.b(\.sharpening), range: 0...150, defaultValue: model.item.isRAW ? 40 : 0, format: n, onCommit: model.commit)
            LSlider(label: "Radius", value: model.b(\.sharpenRadius), range: 0.5...3, defaultValue: 1, step: 0.1, format: { String(format: "%.1f", $0) }, onCommit: model.commit)
            LSlider(label: "Detail", value: model.b(\.sharpenDetail), range: 0...100, defaultValue: 25, format: n, onCommit: model.commit)
            LSlider(label: "Masking", value: model.b(\.sharpenMasking), range: 0...100, defaultValue: 0, format: n, onCommit: model.commit)
            SectionTitle(text: "Noise Reduction")
            LSlider(label: "Amount", value: model.b(\.noiseReduction), range: 0...100, defaultValue: 0, format: n, onCommit: model.commit)
            LSlider(label: "Detail", value: model.b(\.noiseDetail), range: 0...100, defaultValue: 50, format: n, onCommit: model.commit)
            LSlider(label: "Contrast", value: model.b(\.noiseContrast), range: 0...100, defaultValue: 0, format: n, onCommit: model.commit)
            SectionTitle(text: "Color Noise Reduction")
            LSlider(label: "Amount", value: model.b(\.colorNoiseReduction), range: 0...100, defaultValue: model.item.isRAW ? 25 : 0, format: n, onCommit: model.commit)
            LSlider(label: "Detail", value: model.b(\.colorNoiseDetail), range: 0...100, defaultValue: 50, format: n, onCommit: model.commit)
            LSlider(label: "Smoothness", value: model.b(\.colorNoiseSmoothness), range: 0...100, defaultValue: 50, format: n, onCommit: model.commit)
        }
    }
}

// MARK: - Optics

struct OpticsPanel: View {
    @ObservedObject var model: EditorModel
    @State private var pickLens = false
    func n(_ v: Double) -> String { "\(Int(v.rounded()))" }

    var body: some View {
        PanelScroll {
            Toggle("Remove Chromatic Aberration", isOn: model.bool(\.removeChromaticAberration)).font(.system(size: 14))
            Toggle("Enable Lens Corrections", isOn: model.bool(\.enableLensCorrection)).font(.system(size: 14))
            if model.settings.enableLensCorrection {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lens Profile").font(.system(size: 12)).foregroundStyle(Theme.text2)
                        if let lens = model.activeLens {
                            Text(lens.displayName).font(.system(size: 14, weight: .medium)).lineLimit(2)
                            Text(model.settings.lensProfileID == nil ? "Detected automatically" : "Chosen manually")
                                .font(.system(size: 11)).foregroundStyle(Theme.text2)
                        } else if !model.lensSearchDone {
                            ProgressView()
                        } else {
                            Text(model.source?.lensModel.map { "No profile for “\($0)”" } ?? "No lens info in this photo")
                                .font(.system(size: 13)).foregroundStyle(.orange)
                            if model.item.isRAW {
                                Text("Built-in camera corrections are still applied.").font(.system(size: 11)).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                    Spacer()
                    Button("Choose") { pickLens = true }.buttonStyle(.bordered)
                }.padding(.vertical, 6)
                if model.activeLens != nil {
                    LSlider(label: "Distortion", value: model.b(\.lensDistortionAmount), range: 0...200, defaultValue: 100, format: n, onCommit: model.commit)
                    LSlider(label: "Vignetting", value: model.b(\.lensVignetteAmount), range: 0...200, defaultValue: 100, format: n, onCommit: model.commit)
                }
            }
            SectionTitle(text: "Manual")
            LSlider(label: "Distortion", value: model.b(\.manualDistortion), onCommit: model.commit)
            LSlider(label: "Vignetting", value: model.b(\.manualVignette), onCommit: model.commit)
            if model.settings.manualVignette != 0 {
                LSlider(label: "Midpoint", value: model.b(\.manualVignetteMidpoint), range: 0...100, defaultValue: 50, format: n, onCommit: model.commit)
            }
            SectionTitle(text: "Defringe")
            LSlider(label: "Purple Amount", value: model.b(\.defringePurple), range: 0...20, defaultValue: 0, format: n, onCommit: model.commit)
            if model.settings.defringePurple > 0 {
                LSlider(label: "Purple Hue (low)", value: model.b(\.purpleHueLow), range: 0...100, defaultValue: 30, format: n, onCommit: model.commit)
                LSlider(label: "Purple Hue (high)", value: model.b(\.purpleHueHigh), range: 0...100, defaultValue: 70, format: n, onCommit: model.commit)
            }
            LSlider(label: "Green Amount", value: model.b(\.defringeGreen), range: 0...20, defaultValue: 0, format: n, onCommit: model.commit)
            if model.settings.defringeGreen > 0 {
                LSlider(label: "Green Hue (low)", value: model.b(\.greenHueLow), range: 0...100, defaultValue: 40, format: n, onCommit: model.commit)
                LSlider(label: "Green Hue (high)", value: model.b(\.greenHueHigh), range: 0...100, defaultValue: 60, format: n, onCommit: model.commit)
            }
        }
        .sheet(isPresented: $pickLens) { LensPicker(model: model) }
    }
}

struct LensPicker: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var lenses: [LensProfile] = []

    var results: [LensProfile] {
        let q = query.lowercased().split(separator: " ")
        guard !q.isEmpty else { return Array(lenses.prefix(300)) }
        return Array(lenses.filter { l in let n = l.displayName.lowercased(); return q.allSatisfy { n.contains($0) } }.prefix(300))
    }

    var body: some View {
        NavigationStack {
            List {
                Button("Automatic (from photo info)") { model.edit { $0.lensProfileID = nil }; dismiss() }
                ForEach(results) { l in
                    Button {
                        model.edit { $0.lensProfileID = l.id; $0.enableLensCorrection = true }; dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(l.displayName).foregroundStyle(.white)
                            Text(l.mounts.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.text2)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search \(lenses.count) lenses")
            .navigationTitle("Lens Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                let l = await Task.detached { LensDatabase.shared.loadIfNeeded(); return LensDatabase.shared.lenses }.value
                lenses = l
                if let m = model.source?.lensModel, query.isEmpty { query = LensDatabase.tokens(m).prefix(2).joined(separator: " ") }
            }
        }
    }
}

// MARK: - Geometry

struct GeometryPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        PanelScroll {
            LSlider(label: "Vertical", value: model.b(\.vertical), onCommit: model.commit)
            LSlider(label: "Horizontal", value: model.b(\.horizontal), onCommit: model.commit)
            LSlider(label: "Rotate", value: model.b(\.rotate), range: -10...10, step: 0.1, format: { String(format: "%+.1f°", $0) }, onCommit: model.commit)
            LSlider(label: "Aspect", value: model.b(\.aspect), onCommit: model.commit)
            LSlider(label: "Scale", value: model.b(\.scale), range: 50...150, defaultValue: 100, format: { "\(Int($0))" }, onCommit: model.commit)
            LSlider(label: "Offset X", value: model.b(\.offsetX), onCommit: model.commit)
            LSlider(label: "Offset Y", value: model.b(\.offsetY), onCommit: model.commit)
        }
    }
}
