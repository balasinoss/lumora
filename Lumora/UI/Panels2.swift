import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presets

struct PresetsPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var store = PresetStore.shared
    @State private var category: String = "All"
    @State private var showImport = false
    @State private var showSave = false
    @State private var thumbs: [UUID: UIImage] = [:]
    @State private var importMessage: String?

    var shown: [Preset] { category == "All" ? store.presets : store.presets.filter { $0.category == category } }

    var body: some View {
        PanelScroll {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: "All", selected: category == "All") { category = "All" }
                    ForEach(store.categories, id: \.self) { c in Chip(title: c, selected: category == c) { category = c } }
                }
            }
            if let p = model.activePreset {
                VStack(spacing: 2) {
                    HStack {
                        Text(p.name).font(.system(size: 13, weight: .bold))
                        Spacer()
                        Button("Done") { model.clearPresetSession() }.font(.system(size: 13, weight: .semibold))
                    }
                    LSlider(label: "Amount", value: Binding(get: { model.presetAmount }, set: { model.setPresetAmount($0) }),
                            range: 0...200, defaultValue: 100, format: { "\(Int($0))" }, onCommit: model.commit)
                }
                .padding(10).background(Theme.panel2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).padding(.top, 8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(shown) { p in
                    Button { model.applyPreset(p) } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Theme.panel2
                                if let t = thumbs[p.id] { Image(uiImage: t).resizable().scaledToFill() }
                                else { ProgressView().controlSize(.small) }
                            }
                            .frame(height: 84).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.activePreset?.id == p.id ? Theme.accent : Color.clear, lineWidth: 2))
                            Text(p.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Text(p.category)
                        if !p.builtIn {
                            Button(role: .destructive) { store.delete(p) } label: { Label("Delete Preset", systemImage: "trash") }
                        }
                    }
                }
            }
            .padding(.top, 10)
            HStack(spacing: 10) {
                Button { showSave = true } label: {
                    Label("Save as Preset", systemImage: "plus").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10).background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
                }
                Button { showImport = true } label: {
                    Label("Import Lightroom", systemImage: "square.and.arrow.down").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10).background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .foregroundStyle(.white).padding(.top, 12)
            if let m = importMessage { Text(m).font(.system(size: 12)).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .task(id: store.presets.count) { await renderThumbs() }
        .fileImporter(isPresented: $showImport, allowedContentTypes: PresetImporter.types, allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { importMessage = PresetImporter.importFiles(urls) }
        }
        .sheet(isPresented: $showSave) { SavePresetSheet(model: model).presentationDetents([.medium]) }
    }

    /// Small previews of each preset on the current photo.
    func renderThumbs() async {
        guard let source = model.source else { return }
        let base = model.settings
        let list = store.presets.filter { thumbs[$0.id] == nil }
        let ctx = RenderPipeline.shared.context
        let results: [(UUID, UIImage)] = await Task.detached(priority: .utility) {
            guard let small = source.previewBase(settings: base, context: ctx, maxDimension: 300) else { return [] }
            let full = min(source.fullSize.width, source.fullSize.height)
            var out: [(UUID, UIImage)] = []
            for p in list {
                let s = PresetStore.apply(p, amount: 1, to: base)
                let info = RenderPipeline.info(for: source, settings: s, pixelScale: min(small.extent.width, small.extent.height) / max(full, 1))
                if let cg = RenderPipeline.shared.cgImage(RenderPipeline.shared.process(small, settings: s, info: info)) {
                    out.append((p.id, UIImage(cgImage: cg)))
                }
            }
            return out
        }.value
        for (id, img) in results { thumbs[id] = img }
    }
}

enum PresetImporter {
    static var types: [UTType] {
        var t: [UTType] = [.xml, .data, .plainText]
        if let a = UTType(filenameExtension: "lrtemplate") { t.append(a) }
        if let b = UTType(filenameExtension: "xmp") { t.append(b) }
        return t
    }

    /// Imports .lrtemplate / .xmp files. Category = text before " - " in the preset name (e.g. "Presetpro").
    static func importFiles(_ urls: [URL]) -> String {
        var ok = 0, failed: [String] = []
        for u in urls {
            let access = u.startAccessingSecurityScopedResource()
            defer { if access { u.stopAccessingSecurityScopedResource() } }
            do {
                let (title, group, lr) = try LightroomImport.read(u)
                let (category, name) = LightroomImport.splitTitle(title, group: group)
                let values = LightroomImport.convert(lr)
                guard !values.isEmpty else { failed.append(u.lastPathComponent); continue }
                PresetStore.shared.save(Preset(name: name, category: category, values: values))
                ok += 1
            } catch {
                failed.append(u.lastPathComponent)
            }
        }
        var msg = "Imported \(ok) preset\(ok == 1 ? "" : "s")."
        if !failed.isEmpty { msg += " Couldn't read: " + failed.joined(separator: ", ") }
        return msg
    }
}

struct SavePresetSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var category = "My Presets"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Preset name", text: $name)
                TextField("Category", text: $category)
                Text("Saves your current Light, Color, Effects, Detail and Optics settings. Crop, masks and healing stay with the photo.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            .navigationTitle("New Preset").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PresetStore.shared.save(PresetStore.fromSettings(model.settings, name: name, category: category.isEmpty ? "My Presets" : category))
                        dismiss()
                    }.disabled(name.isEmpty)
                }
            }
        }
    }
}

/// Pick a preset to apply to many photos from the library.
struct ApplyPresetSheet: View {
    let items: [PhotoItem]
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store = PresetStore.shared
    @State private var amount: Double = 100

    var body: some View {
        NavigationStack {
            List {
                Section { LSlider(label: "Amount", value: $amount, range: 0...200, defaultValue: 100, format: { "\(Int($0))" }) }
                ForEach(store.categories, id: \.self) { c in
                    Section(c) {
                        ForEach(store.presets.filter { $0.category == c }) { p in
                            Button(p.name) {
                                LibraryStore.shared.applyPreset(p, amount: amount / 100, to: items)
                                dismiss()
                            }.foregroundStyle(.white)
                        }
                    }
                }
            }
            .navigationTitle("Apply to \(items.count) photo\(items.count == 1 ? "" : "s")").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Heal

struct HealPanel: View {
    @ObservedObject var model: EditorModel
    func n(_ v: Double) -> String { "\(Int(v.rounded()))" }
    var body: some View {
        PanelScroll {
            Picker("", selection: $model.healClone) { Text("Heal").tag(false); Text("Clone").tag(true) }.pickerStyle(.segmented)
            Text("Tap a spot on the photo to remove it. Lumora picks a matching area automatically — drag the dashed circle to choose another source.")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            LSlider(label: "Size", value: Binding(get: { model.healSize * 1000 }, set: { v in
                model.healSize = v / 1000
                if model.selectedHeal != nil { model.updateHeal { $0.radius = v / 1000 } }
            }), range: 5...200, defaultValue: 40, format: n, onCommit: { model.refreshHealShift(); model.commit() })
            if let sp = model.selectedHeal {
                LSlider(label: "Feather", value: Binding(get: { sp.feather * 100 }, set: { v in model.updateHeal { $0.feather = v / 100 } }),
                        range: 0...100, defaultValue: 50, format: n, onCommit: model.commit)
                HStack {
                    Toggle("Clone (no color matching)", isOn: Binding(get: { sp.clone }, set: { v in model.updateHeal { $0.clone = v }; model.refreshHealShift(); model.commit() }))
                        .font(.system(size: 13)).tint(Theme.accent)
                }
                Button(role: .destructive) {
                    model.edit { $0.healSpots.removeAll { $0.id == sp.id } }; model.selectedHealID = nil
                } label: { Label("Delete this spot", systemImage: "trash") }.font(.system(size: 13)).padding(.top, 6)
            }
            if !model.settings.healSpots.isEmpty {
                Button("Remove all spots (\(model.settings.healSpots.count))") { model.edit { $0.healSpots = [] }; model.selectedHealID = nil }
                    .font(.footnote).padding(.top, 8)
            }
        }
    }
}

// MARK: - Point colour & calibration (used by ColorPanel)

struct PointColorSection: View {
    @ObservedObject var model: EditorModel
    func n(_ v: Double) -> String { "\(Int(v.rounded()))" }
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Button { model.pickingColor.toggle() } label: {
                    Label(model.pickingColor ? "Tap the photo…" : "Pick a color", systemImage: "eyedropper")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(model.pickingColor ? .black : .white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(model.pickingColor ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.panel2), in: Capsule())
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.settings.pointColors) { pc in
                            Circle().fill(Color(red: pc.r, green: pc.g, blue: pc.b)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white, lineWidth: model.selectedPointID == pc.id ? 2.5 : 0).padding(-3))
                                .onTapGesture { model.selectedPointID = pc.id }
                        }
                    }.padding(4)
                }
            }.padding(.top, 8)
            if let pc = model.settings.pointColors.first(where: { $0.id == model.selectedPointID }) {
                LSlider(label: "Hue", value: Binding(get: { pc.hueShift }, set: { v in model.updatePoint { $0.hueShift = v } }), onCommit: model.commit)
                LSlider(label: "Saturation", value: Binding(get: { pc.satShift }, set: { v in model.updatePoint { $0.satShift = v } }), onCommit: model.commit)
                LSlider(label: "Luminance", value: Binding(get: { pc.lumShift }, set: { v in model.updatePoint { $0.lumShift = v } }), onCommit: model.commit)
                LSlider(label: "Range", value: Binding(get: { pc.range }, set: { v in model.updatePoint { $0.range = v } }),
                        range: 0...100, defaultValue: 50, format: n, onCommit: model.commit)
                Button(role: .destructive) {
                    model.edit { $0.pointColors.removeAll { $0.id == pc.id } }; model.selectedPointID = nil
                } label: { Label("Remove color", systemImage: "trash") }.font(.footnote).padding(.top, 6)
            } else {
                Text("Pick a color in the photo (a jersey, the court, skin) and shift just that color.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        }
    }
}

struct CalibrationSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 2) {
            SectionTitle(text: "Shadows")
            LSlider(label: "Tint", value: model.b(\.calShadowTint), gradient: Tracks.tint, onCommit: model.commit)
            SectionTitle(text: "Red Primary")
            LSlider(label: "Hue", value: model.b(\.calRedHue), gradient: [.pink, .red, .orange], onCommit: model.commit)
            LSlider(label: "Saturation", value: model.b(\.calRedSat), gradient: [Color(white: 0.6), .red], onCommit: model.commit)
            SectionTitle(text: "Green Primary")
            LSlider(label: "Hue", value: model.b(\.calGreenHue), gradient: [.yellow, .green, .teal], onCommit: model.commit)
            LSlider(label: "Saturation", value: model.b(\.calGreenSat), gradient: [Color(white: 0.6), .green], onCommit: model.commit)
            SectionTitle(text: "Blue Primary")
            LSlider(label: "Hue", value: model.b(\.calBlueHue), gradient: [.cyan, .blue, .purple], onCommit: model.commit)
            LSlider(label: "Saturation", value: model.b(\.calBlueSat), gradient: [Color(white: 0.6), .blue], onCommit: model.commit)
        }
    }
}

// MARK: - History & versions

struct HistorySheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array((0..<model.history.count).reversed()), id: \.self) { i in
                    Button {
                        model.jumpToHistory(i)
                    } label: {
                        HStack {
                            Text(model.history[i].label).foregroundStyle(i <= model.historyIndex ? Color.white : Theme.text2)
                            Spacer()
                            if i == model.historyIndex { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
            .navigationTitle("History").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct VersionsSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Version name (e.g. B&W)", text: $name)
                        Button("Save current") { model.saveVersion(named: name); name = "" }
                    }
                } footer: { Text("Versions keep different edits of the same photo without copying the file.") }
                Section("Saved versions") {
                    ForEach(model.versions.reversed()) { v in
                        Button { model.applyVersion(v); dismiss() } label: {
                            VStack(alignment: .leading) {
                                Text(v.name).foregroundStyle(.white)
                                Text(v.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.text2)
                            }
                        }
                        .swipeActions { Button(role: .destructive) { model.deleteVersion(v) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
            .navigationTitle("Versions").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
