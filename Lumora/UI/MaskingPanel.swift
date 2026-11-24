import SwiftUI

struct MaskingPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Group {
            if let mask = model.selectedMask {
                MaskDetail(model: model, mask: mask)
            } else {
                maskList
            }
        }
        .onAppear { model.detectPeople() }
    }

    var maskList: some View {
        PanelScroll {
            if let e = model.maskError {
                Text(e).font(.system(size: 12)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.settings.masks.isEmpty {
                SectionTitle(text: "Your masks")
                ForEach(model.settings.masks) { m in
                    HStack(spacing: 12) {
                        Image(systemName: m.kind.icon).frame(width: 34, height: 34).background(Theme.panel2, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.system(size: 14, weight: .semibold))
                            Text(m.adjust.isNeutral ? "No adjustments yet" : "Adjusted").font(.system(size: 11)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        Button { model.edit { s in if let i = s.masks.firstIndex(where: { $0.id == m.id }) { s.masks[i].visible.toggle() } } } label: {
                            Image(systemName: m.visible ? "eye" : "eye.slash").foregroundStyle(m.visible ? .white : Theme.text2)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                    .padding(10)
                    .background(Theme.panel2.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedMaskID = m.id }
                    .contextMenu {
                        Button { model.duplicateMask(m.id, invert: false) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { model.duplicateMask(m.id, invert: true) } label: { Label("Duplicate & Invert", systemImage: "circle.righthalf.filled") }
                        Button(role: .destructive) { model.deleteMask(m.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            SectionTitle(text: "AI masks")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 8)], spacing: 8) {
                addButton(.subject)
                addButton(.sky)
                addButton(.background)
                addButton(.people)
                if let n = model.peopleCount, n > 1 {
                    ForEach(0..<min(n, 4), id: \.self) { i in addButton(.person, personIndex: i, title: "Person \(i + 1)") }
                }
            }
            SectionTitle(text: "Manual masks")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 8)], spacing: 8) {
                addButton(.brush)
                addButton(.linear)
                addButton(.radial)
            }
        }
    }

    func addButton(_ kind: MaskKind, personIndex: Int = 0, title: String? = nil) -> some View {
        Button { model.addMask(kind, personIndex: personIndex) } label: {
            VStack(spacing: 6) {
                Image(systemName: kind.icon).font(.system(size: 20))
                Text(title ?? kind.title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
        }
        .disabled(model.maskBusy != nil)
    }
}

struct MaskDetail: View {
    @ObservedObject var model: EditorModel
    let mask: MaskLayer
    @State private var page = 0
    func n(_ v: Double) -> String { "\(Int(v.rounded()))" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.selectedMaskID = nil; model.brushMode = .off } label: {
                    Image(systemName: "chevron.left").frame(width: 32, height: 32).background(Theme.panel2, in: Circle())
                }
                Image(systemName: mask.kind.icon).foregroundStyle(Theme.accent)
                Text(mask.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { model.showMaskOverlay.toggle() } label: {
                    Image(systemName: model.showMaskOverlay ? "circle.dashed.inset.filled" : "circle.dashed")
                        .frame(width: 32, height: 32).background(Theme.panel2, in: Circle())
                }
                Button { model.updateMask { $0.invert.toggle() }; model.commit() } label: {
                    Image(systemName: "circle.righthalf.filled").foregroundStyle(mask.invert ? Theme.accent : .white)
                        .frame(width: 32, height: 32).background(Theme.panel2, in: Circle())
                }
                Button(role: .destructive) { model.deleteMask(mask.id) } label: {
                    Image(systemName: "trash").frame(width: 32, height: 32).background(Theme.panel2, in: Circle())
                }
            }
            .padding(.horizontal, 18).padding(.top, 6)

            Picker("", selection: $page) {
                Text("Adjust").tag(0); Text("Refine").tag(1)
            }
            .pickerStyle(.segmented).padding(.horizontal, 18).padding(.top, 10)
            .onChange(of: page) { _, p in model.brushMode = p == 1 ? (model.brushMode == .off ? .add : model.brushMode) : .off }

            if page == 0 {
                adjustments
            } else {
                refine
            }
        }
        .onAppear { if mask.kind == .brush { page = 1; model.brushMode = .add } }
    }

    var adjustments: some View {
        PanelScroll {
            LSlider(label: "Exposure", value: model.maskBinding(\.exposure), range: -4...4, step: 0.01, format: { String(format: "%+.2f", $0) }, onCommit: model.commit)
            LSlider(label: "Contrast", value: model.maskBinding(\.contrast), onCommit: model.commit)
            LSlider(label: "Highlights", value: model.maskBinding(\.highlights), onCommit: model.commit)
            LSlider(label: "Shadows", value: model.maskBinding(\.shadows), onCommit: model.commit)
            LSlider(label: "Whites", value: model.maskBinding(\.whites), onCommit: model.commit)
            LSlider(label: "Blacks", value: model.maskBinding(\.blacks), onCommit: model.commit)
            SectionTitle(text: "Color")
            LSlider(label: "Temp", value: model.maskBinding(\.temperature), gradient: Tracks.temp, onCommit: model.commit)
            LSlider(label: "Tint", value: model.maskBinding(\.tint), gradient: Tracks.tint, onCommit: model.commit)
            LSlider(label: "Saturation", value: model.maskBinding(\.saturation), onCommit: model.commit)
            SectionTitle(text: "Effects")
            LSlider(label: "Texture", value: model.maskBinding(\.texture), onCommit: model.commit)
            LSlider(label: "Clarity", value: model.maskBinding(\.clarity), onCommit: model.commit)
            LSlider(label: "Dehaze", value: model.maskBinding(\.dehaze), onCommit: model.commit)
            LSlider(label: "Sharpness", value: model.maskBinding(\.sharpness), onCommit: model.commit)
            SectionTitle(text: "Mask")
            LSlider(label: "Amount", value: Binding(get: { mask.opacity }, set: { v in model.updateMask { $0.opacity = v } }),
                    range: 0...100, defaultValue: 100, format: n, onCommit: model.commit)
            if mask.kind == .radial {
                LSlider(label: "Feather", value: Binding(get: { (mask.radial?.feather ?? 0.5) * 100 }, set: { v in model.updateMask { $0.radial?.feather = v / 100 } }),
                        range: 0...100, defaultValue: 50, format: n, onCommit: model.commit)
                Toggle("Adjust outside the circle", isOn: Binding(get: { !(mask.radial?.inside ?? true) }, set: { v in model.updateMask { $0.radial?.inside = !v }; model.commit() }))
                    .font(.system(size: 13)).tint(Theme.accent)
            }
            Button("Reset adjustments") { model.updateMask { $0.adjust = LocalAdjust() }; model.commit() }
                .font(.footnote).padding(.top, 8)
        }
    }

    var refine: some View {
        PanelScroll {
            HStack(spacing: 8) {
                Chip(title: "Add", selected: model.brushMode == .add) { model.brushMode = .add }
                Chip(title: "Erase", selected: model.brushMode == .erase) { model.brushMode = .erase }
                Chip(title: "Done", selected: false) { model.brushMode = .off }
                Spacer()
                Button { model.updateMask { _ = $0.strokes.popLast() }; model.commit() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 34, height: 34).background(Theme.panel2, in: Circle())
                }.disabled(mask.strokes.isEmpty)
            }
            Text(model.brushMode == .off ? "Choose Add or Erase, then paint on the photo." :
                    (model.brushMode == .add ? "Paint on the photo to add to the mask." : "Paint on the photo to remove from the mask."))
                .font(.system(size: 12)).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            LSlider(label: "Size", value: Binding(get: { model.brushSize * 1000 }, set: { model.brushSize = $0 / 1000 }),
                    range: 5...300, defaultValue: 60, format: n)
            LSlider(label: "Feather", value: Binding(get: { model.brushFeather * 100 }, set: { model.brushFeather = $0 / 100 }),
                    range: 0...100, defaultValue: 50, format: n)
            LSlider(label: "Flow", value: Binding(get: { model.brushFlow * 100 }, set: { model.brushFlow = $0 / 100 }),
                    range: 5...100, defaultValue: 100, format: n)
            if !mask.strokes.isEmpty {
                Button("Clear brush strokes", role: .destructive) { model.updateMask { $0.strokes = [] }; model.commit() }
                    .font(.footnote).padding(.top, 6)
            }
        }
    }
}
