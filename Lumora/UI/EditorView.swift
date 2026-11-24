import SwiftUI
import UIKit

enum EditorTool: String, CaseIterable, Identifiable {
    case profiles = "Presets", crop = "Crop", masking = "Masks", heal = "Heal", light = "Light", color = "Color", effects = "Effects",
         detail = "Detail", optics = "Optics", geometry = "Geometry"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .profiles: return "square.stack.3d.up"
        case .crop: return "crop.rotate"
        case .masking: return "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .heal: return "bandage"
        case .light: return "sun.max"
        case .color: return "thermometer.medium"
        case .effects: return "sparkles"
        case .detail: return "wand.and.stars"
        case .optics: return "camera.aperture"
        case .geometry: return "perspective"
        }
    }
}

/// Rect an image of `size` occupies when fitted into `container` with `inset`.
func fitRect(_ size: CGSize, in container: CGSize, inset: CGFloat = 0) -> CGRect {
    let avail = CGSize(width: max(1, container.width - inset * 2), height: max(1, container.height - inset * 2))
    let s = min(avail.width / max(size.width, 1), avail.height / max(size.height, 1))
    let w = size.width * s, h = size.height * s
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}

struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var tool: EditorTool = .light
    @State private var showHistogram = true
    @State private var showOriginal = false
    @State private var showExport = false
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var panelExpanded = false
    @State private var fullscreen = false
    @State private var splitMode = false
    @State private var split: CGFloat = 0.5
    @State private var splitStart: CGFloat?
    @State private var holdWork: DispatchWorkItem?
    @State private var showHistory = false
    @State private var showVersions = false

    init(item: PhotoItem) { _model = StateObject(wrappedValue: EditorModel(item: item)) }

    var body: some View {
        VStack(spacing: 0) {
            if !fullscreen { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
            imageArea
            if !fullscreen {
                panelContainer.transition(.move(edge: .bottom).combined(with: .opacity))
                toolBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background((fullscreen ? Color.black : Theme.bg).ignoresSafeArea())
        .statusBarHidden(fullscreen)
        .overlay(alignment: .topTrailing) {
            if fullscreen {
                Button { withAnimation(.easeInOut(duration: 0.25)) { fullscreen = false } } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(.white).padding(16)
            }
        }
        .sheet(isPresented: $showHistory) { HistorySheet(model: model).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showVersions) { VersionsSheet(model: model).presentationDetents([.medium, .large]) }
        .onChange(of: tool) { _, t in
            model.cropMode = (t == .crop)
            model.maskMode = (t == .masking || t == .heal)
            if t != .masking { model.drawingObject = false }
            if t != .profiles { model.clearPresetSession() }
            if t != .color { model.pickingColor = false }
            if t != .light { model.curveEditing = false }
            if t != .detail { model.showSharpenMask = false }
            if t != .masking { model.brushMode = .off }
            zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero
        }
        .sheet(isPresented: $showExport) { ExportSheet(model: model).presentationDetents([.medium, .large]) }
    }

    // MARK: Top bar

    var topBar: some View {
        HStack(spacing: 20) {
            Button { model.finish(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34).background(Theme.panel2, in: Circle())
            }
            Spacer()
            Group {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo)
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo)
                Button { splitMode.toggle(); if splitMode { model.loadOriginal() } } label: {
                    Image(systemName: "square.split.2x1").foregroundStyle(splitMode ? Theme.accent : .white)
                }
                Button { withAnimation(.easeInOut(duration: 0.25)) { fullscreen = true } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                Menu {
                    Button { showHistogram.toggle() } label: { Label(showHistogram ? "Hide Histogram" : "Show Histogram", systemImage: "chart.bar.xaxis") }
                    Button { showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    Button { showVersions = true } label: { Label("Versions", systemImage: "square.on.square") }
                    Divider()
                    Button { LibraryStore.shared.clipboard = model.settings } label: { Label("Copy Settings", systemImage: "doc.on.doc") }
                    if let c = LibraryStore.shared.clipboard {
                        Button { model.edit { s in
                            let keep = s; s = c
                            s.crop = keep.crop; s.straighten = keep.straighten; s.rotation90 = keep.rotation90
                            s.lensProfileID = keep.lensProfileID; s.masks = keep.masks; s.aiDenoise = keep.aiDenoise
                        } } label: { Label("Paste Settings", systemImage: "doc.on.clipboard") }
                    }
                    Button(role: .destructive) { model.reset() } label: { Label("Reset All", systemImage: "arrow.counterclockwise") }
                } label: { Image(systemName: "ellipsis") }
            }
            .font(.system(size: 17, weight: .medium))
            Button { showExport = true } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .frame(width: 34, height: 34).background(Theme.gradient, in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Image

    var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg
                if let img = ((showOriginal && tool != .crop && tool != .masking && tool != .heal) ? (model.original ?? model.preview) : model.preview) {
                    if tool == .crop {
                        CropOverlay(model: model, image: img, container: geo.size)
                    } else if tool == .masking || model.curveEditing {
                        let r = fitRect(img.size, in: geo.size, inset: 8)
                        Image(uiImage: img).resizable().frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        if tool == .masking {
                            MaskCanvas(model: model, rect: r)
                        } else {
                            CurveOverlay(model: model, rect: r)
                        }
                    } else if tool == .heal {
                        let r = fitRect(img.size, in: geo.size, inset: 8)
                        Image(uiImage: img).resizable().frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        HealCanvas(model: model, rect: r)
                    } else {
                        mainImage(img, container: geo.size)
                    }
                } else {
                    ProgressView().tint(Theme.accent)
                }
                VStack {
                    HStack(alignment: .top) {
                        if showOriginal { badge("Before") }
                        if model.pickingColor { badge("Tap the photo to pick a color") }
                        if model.showSharpenMask { badge("Sharpening mask · white = sharpened") }
                        if let busy = model.maskBusy { badge(busy, spinner: true) }
                        Spacer()
                        if showHistogram && !fullscreen && tool != .crop && !model.histogram.isEmpty {
                            HistogramView(data: model.histogram).frame(width: 120, height: 58).allowsHitTesting(false)
                        }
                    }
                    Spacer()
                }.padding(10)
            }
            .coordinateSpace(name: "maskcanvas")
            .clipped()
        }
    }

    /// The photo with zoom, tap (full screen), double-tap (zoom), press-and-hold (original) and split view.
    @ViewBuilder func mainImage(_ img: UIImage, container: CGSize) -> some View {
        let r = fitRect(img.size, in: container, inset: fullscreen ? 0 : 8)
        ZStack {
            Image(uiImage: img).resizable().frame(width: r.width, height: r.height)
            if splitMode, let orig = model.original {
                Image(uiImage: orig).resizable().frame(width: r.width, height: r.height)
                    .mask(alignment: .leading) { Rectangle().frame(width: r.width * split) }
                Rectangle().fill(.white).frame(width: 2, height: r.height)
                    .offset(x: r.width * (split - 0.5))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                Circle().fill(.white).frame(width: 30, height: 30)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.black))
                    .offset(x: r.width * (split - 0.5))
                    .gesture(DragGesture()
                        .onChanged { g in
                            if splitStart == nil { splitStart = split }
                            split = min(max(splitStart! + g.translation.width / r.width, 0.02), 0.98)
                        }
                        .onEnded { _ in splitStart = nil })
                Text("Before").font(.system(size: 10, weight: .bold)).padding(5).background(.black.opacity(0.5), in: Capsule())
                    .offset(x: -r.width / 2 + 34, y: -r.height / 2 + 16)
                Text("After").font(.system(size: 10, weight: .bold)).padding(5).background(.black.opacity(0.5), in: Capsule())
                    .offset(x: r.width / 2 - 30, y: -r.height / 2 + 16)
            }
        }
        .scaleEffect(zoom)
        .offset(pan)
        .position(x: r.midX + 0, y: r.midY)
        .contentShape(Rectangle())
        .gesture(MagnificationGesture()
            .onChanged { zoom = max(1, min(8, zoomBase * $0)) }
            .onEnded { _ in zoomBase = zoom; if zoom <= 1.01 { pan = .zero; panBase = .zero } })
        .simultaneousGesture(DragGesture()
            .onChanged { g in if zoom > 1 { pan = CGSize(width: panBase.width + g.translation.width, height: panBase.height + g.translation.height) } }
            .onEnded { _ in panBase = pan })
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) {
                if zoom > 1 { zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero } else { zoom = 2.5; zoomBase = 2.5 }
            }
        }
        .onTapGesture(count: 1, coordinateSpace: .named("maskcanvas")) { loc in
            if model.pickingColor {
                let p = CGPoint(x: (loc.x - r.minX) / r.width, y: (loc.y - r.minY) / r.height)
                if p.x >= 0, p.y >= 0, p.x <= 1, p.y <= 1 { model.pickColor(at: p) }
            } else if !splitMode {
                withAnimation(.easeInOut(duration: 0.25)) { fullscreen.toggle() }
            }
        }
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 12, perform: {}, onPressingChanged: { pressing in
            holdWork?.cancel()
            if pressing {
                let w = DispatchWorkItem {
                    model.loadOriginal()
                    showOriginal = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                holdWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
            } else {
                showOriginal = false
            }
        })
    }

    func badge(_ text: String, spinner: Bool = false) -> some View {
        HStack(spacing: 6) {
            if spinner { ProgressView().controlSize(.mini).tint(.white) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Panel

    var panelContainer: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 36, height: 4).padding(.top, 7)
                .onTapGesture { withAnimation(.spring(duration: 0.3)) { panelExpanded.toggle() } }
            HStack {
                Text(tool.rawValue).font(.system(size: 17, weight: .bold))
                Spacer()
                Button { withAnimation(.spring(duration: 0.3)) { panelExpanded.toggle() } } label: {
                    Image(systemName: panelExpanded ? "chevron.down" : "chevron.up").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text2).frame(width: 28, height: 28).background(Theme.panel2, in: Circle())
                }
            }
            .padding(.horizontal, 18).padding(.top, 4)
            panel
        }
        .frame(height: panelExpanded ? 430 : 300)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Theme.panel)
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22).stroke(Theme.stroke, lineWidth: 1))
        )
        .gesture(DragGesture(minimumDistance: 20).onEnded { g in
            if g.translation.height < -40 { withAnimation(.spring(duration: 0.3)) { panelExpanded = true } }
            if g.translation.height > 40 { withAnimation(.spring(duration: 0.3)) { panelExpanded = false } }
        })
    }

    @ViewBuilder var panel: some View {
        switch tool {
        case .profiles: PresetsPanel(model: model)
        case .crop: CropPanel(model: model)
        case .masking: MaskingPanel(model: model)
        case .heal: HealPanel(model: model)
        case .light: LightPanel(model: model)
        case .color: ColorPanel(model: model)
        case .effects: EffectsPanel(model: model)
        case .detail: DetailPanel(model: model)
        case .optics: OpticsPanel(model: model)
        case .geometry: GeometryPanel(model: model)
        }
    }

    var toolBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(EditorTool.allCases) { t in
                        ToolButton(tool: t, selected: tool == t) {
                            withAnimation(.easeOut(duration: 0.15)) { tool = t }
                            proxy.scrollTo(t.id, anchor: .center)
                        }
                        .id(t.id)
                    }
                }.padding(.horizontal, 8)
            }
        }
        .padding(.top, 8).padding(.bottom, 4)
        .background(Theme.bg)
    }
}

struct ToolButton: View {
    let tool: EditorTool
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tool.icon).font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 30)
                    .background(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear), in: Capsule())
                    .foregroundStyle(selected ? Color.black : Color.white)
                Text(tool.rawValue).font(.system(size: 10, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.white : Theme.text2)
            }
            .frame(width: 62)
        }
    }
}

// MARK: - Curve on the photo

/// Drag anywhere on the photo to shape the curve: grabs the nearest point, or adds one where you touch.
struct CurveOverlay: View {
    @ObservedObject var model: EditorModel
    let rect: CGRect
    @State private var dragIndex: Int?
    @State private var grabOffset: CGSize = .zero
    @State private var grabTime = Date()
    @State private var createdNew = false

    var color: Color {
        switch model.curveChannel {
        case .master: return .white
        case .red: return Color(red: 1, green: 0.35, blue: 0.35)
        case .green: return Color(red: 0.35, green: 0.95, blue: 0.45)
        case .blue: return Color(red: 0.4, green: 0.6, blue: 1)
        }
    }

    private func toView(_ p: CurvePoint) -> CGPoint { CGPoint(x: rect.minX + CGFloat(p.x) * rect.width, y: rect.maxY - CGFloat(p.y) * rect.height) }
    private func toCurve(_ v: CGPoint) -> (Double, Double) {
        (min(max(Double((v.x - rect.minX) / rect.width), 0), 1), min(max(Double((rect.maxY - v.y) / rect.height), 0), 1))
    }

    var body: some View {
        let pts = model.settings.curve(model.curveChannel)
        let r = rect
        ZStack {
            Rectangle().fill(Color.black.opacity(0.3)).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            Path { p in
                for i in 1..<4 {
                    let x = r.minX + r.width * CGFloat(i) / 4, y = r.minY + r.height * CGFloat(i) / 4
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }.stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            Path { p in p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)) }
                .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            Path { p in
                for i in 0...120 {
                    let x = Double(i) / 120
                    let pt = toView(CurvePoint(x: x, y: Curves.evaluate(pts, x)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }.stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).shadow(color: .black.opacity(0.6), radius: 2)
            ForEach(Array(pts.enumerated()), id: \.offset) { i, pt in
                Circle().fill(dragIndex == i ? color : Color.black.opacity(0.6))
                    .overlay(Circle().stroke(color, lineWidth: 2))
                    .frame(width: dragIndex == i ? 24 : 16, height: dragIndex == i ? 24 : 16)
                    .position(toView(pt))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in drag(g) }
            .onEnded { g in
                // a quick tap on an existing middle point (without moving) deletes it
                let pts = model.settings.curve(model.curveChannel)
                if let i = dragIndex, !createdNew, hypot(g.translation.width, g.translation.height) < 4,
                   Date().timeIntervalSince(grabTime) < 0.3, i != 0, i != pts.count - 1 {
                    var p = pts; p.remove(at: i)
                    model.settings.setCurve(model.curveChannel, p)
                }
                dragIndex = nil
                model.commit()
            })
    }

    private func drag(_ g: DragGesture.Value) {
        var p = model.settings.curve(model.curveChannel)
        if dragIndex == nil {
            grabTime = Date()
            let s = g.startLocation
            var best: (Int, CGFloat)?
            for (i, q) in p.enumerated() {
                let v = toView(q)
                let d = hypot(v.x - s.x, v.y - s.y)
                if d < 44 && (best == nil || d < best!.1) { best = (i, d) }
            }
            if let best {
                dragIndex = best.0
                createdNew = false
                let v = toView(p[best.0])
                grabOffset = CGSize(width: v.x - s.x, height: v.y - s.y)
            } else {
                // touch anywhere: add a point on the curve at this x; vertical finger movement bends the curve
                let (x, _) = toCurve(s)
                let y = Curves.evaluate(p, x)
                p.append(CurvePoint(x: x, y: y))
                p.sort { $0.x < $1.x }
                dragIndex = p.firstIndex { abs($0.x - x) < 1e-9 }
                createdNew = true
                let v = toView(CurvePoint(x: x, y: y))
                grabOffset = CGSize(width: v.x - s.x, height: v.y - s.y)
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        guard let i = dragIndex, i < p.count else { return }
        var (nx, ny) = toCurve(CGPoint(x: g.location.x + grabOffset.width, y: g.location.y + grabOffset.height))
        if i == 0 { nx = min(nx, p.count > 1 ? p[1].x - 0.01 : 1) }
        else if i == p.count - 1 { nx = max(nx, p[i - 1].x + 0.01) }
        else { nx = min(max(nx, p[i - 1].x + 0.01), p[i + 1].x - 0.01) }
        p[i] = CurvePoint(x: nx, y: ny)
        model.settings.setCurve(model.curveChannel, p)
    }
}

// MARK: - Mask canvas (brush painting + gradient handles)

struct MaskCanvas: View {
    @ObservedObject var model: EditorModel
    let rect: CGRect
    @State private var painting = false
    @State private var objStart: CGPoint?
    @State private var objEnd: CGPoint?

    func norm(_ p: CGPoint) -> NPoint {
        NPoint(x: Double((p.x - rect.minX) / rect.width), y: Double((p.y - rect.minY) / rect.height))
    }
    func view(_ p: NPoint) -> CGPoint { CGPoint(x: rect.minX + CGFloat(p.x) * rect.width, y: rect.minY + CGFloat(p.y) * rect.height) }

    var body: some View {
        ZStack {
            if model.drawingObject {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { g in objStart = g.startLocation; objEnd = g.location }
                        .onEnded { _ in
                            if let a = objStart, let b = objEnd {
                                let n0 = norm(a), n1 = norm(b)
                                let x = max(0, min(n0.x, n1.x)), y = max(0, min(n0.y, n1.y))
                                let w = min(1 - x, abs(n1.x - n0.x)), h = min(1 - y, abs(n1.y - n0.y))
                                if w > 0.02 && h > 0.02 { model.addObjectMask(rect: NormRect(x: x, y: y, w: w, h: h)) }
                            }
                            objStart = nil; objEnd = nil
                        })
                if let a = objStart, let b = objEnd {
                    Rectangle().stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: abs(b.x - a.x), height: abs(b.y - a.y))
                        .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                        .allowsHitTesting(false)
                }
            } else if let m = model.selectedMask {
                if model.brushMode != .off {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                if !painting { painting = true; model.beginStroke(at: norm(g.location)) }
                                else { model.continueStroke(to: norm(g.location)) }
                            }
                            .onEnded { _ in painting = false; model.commit() })
                } else if m.kind == .linear, let g = m.linear {
                    linearHandles(g)
                } else if m.kind == .radial, let g = m.radial {
                    radialHandles(g)
                }
            }
        }
    }

    @ViewBuilder func linearHandles(_ g: MaskLinearGradient) -> some View {
        let a = view(g.start), b = view(g.end)
        Path { p in p.move(to: a); p.addLine(to: b) }.stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        // lines perpendicular to the direction at both ends
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let nx = -dy / len * 600, ny = dx / len * 600
        Path { p in
            p.move(to: CGPoint(x: a.x - nx, y: a.y - ny)); p.addLine(to: CGPoint(x: a.x + nx, y: a.y + ny))
            p.move(to: CGPoint(x: b.x - nx, y: b.y - ny)); p.addLine(to: CGPoint(x: b.x + nx, y: b.y + ny))
        }.stroke(Color.white.opacity(0.7), lineWidth: 1)
        handle(at: a) { t in model.updateMask { $0.linear?.start = norm(t) } }
        handle(at: b) { t in model.updateMask { $0.linear?.end = norm(t) } }
        handle(at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), filled: true) { t in
            let mid = norm(t)
            let cx = (g.start.x + g.end.x) / 2, cy = (g.start.y + g.end.y) / 2
            model.updateMask {
                $0.linear?.start = NPoint(x: g.start.x + mid.x - cx, y: g.start.y + mid.y - cy)
                $0.linear?.end = NPoint(x: g.end.x + mid.x - cx, y: g.end.y + mid.y - cy)
            }
        }
    }

    @ViewBuilder func radialHandles(_ g: MaskRadialGradient) -> some View {
        let c = view(g.center)
        let rx = CGFloat(g.radiusX) * rect.width, ry = CGFloat(g.radiusY) * rect.height
        Ellipse().stroke(.white, lineWidth: 1.5).frame(width: rx * 2, height: ry * 2).position(c).allowsHitTesting(false)
        Ellipse().stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(width: rx * 2 * CGFloat(1 - g.feather * 0.95), height: ry * 2 * CGFloat(1 - g.feather * 0.95)).position(c).allowsHitTesting(false)
        handle(at: c, filled: true) { t in model.updateMask { $0.radial?.center = norm(t) } }
        handle(at: CGPoint(x: c.x + rx, y: c.y)) { t in model.updateMask { $0.radial?.radiusX = max(0.02, Double(abs(t.x - c.x) / rect.width)) } }
        handle(at: CGPoint(x: c.x, y: c.y - ry)) { t in model.updateMask { $0.radial?.radiusY = max(0.02, Double(abs(t.y - c.y) / rect.height)) } }
    }

    func handle(at p: CGPoint, filled: Bool = false, move: @escaping (CGPoint) -> Void) -> some View {
        Circle().fill(filled ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white))
            .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
            .frame(width: 22, height: 22)
            .padding(12).contentShape(Circle())
            .position(p)
            .gesture(DragGesture(coordinateSpace: .named("maskcanvas")).onChanged { g in move(g.location) }.onEnded { _ in model.commit() })
    }
}


// MARK: - Heal canvas

struct HealCanvas: View {
    @ObservedObject var model: EditorModel
    let rect: CGRect
    @State private var dragging: (UUID, Bool)?   // (spot, isSource)
    @State private var start: (Double, Double)?

    func view(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + CGFloat(x) * rect.width, y: rect.minY + CGFloat(y) * rect.height) }

    var body: some View {
        let short = min(rect.width, rect.height)
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named("maskcanvas")) { loc in
                    let p = CGPoint(x: (loc.x - rect.minX) / rect.width, y: (loc.y - rect.minY) / rect.height)
                    guard p.x >= 0, p.y >= 0, p.x <= 1, p.y <= 1 else { return }
                    model.addHeal(at: p)
                }
            ForEach(model.settings.healSpots) { sp in
                let d = view(sp.x, sp.y), s = view(sp.srcX, sp.srcY)
                let rr = CGFloat(sp.radius) * short
                let sel = sp.id == model.selectedHealID
                Path { p in p.move(to: s); p.addLine(to: d) }.stroke(Color.white.opacity(sel ? 0.8 : 0.3), lineWidth: 1).allowsHitTesting(false)
                Circle().stroke(Color.white.opacity(sel ? 1 : 0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: rr * 2, height: rr * 2).contentShape(Circle()).position(s)
                    .gesture(drag(sp, source: true))
                Circle().stroke(sel ? Theme.accent : Color.white.opacity(0.7), lineWidth: 2)
                    .background(Circle().fill(Color.white.opacity(0.001)))
                    .frame(width: rr * 2, height: rr * 2).contentShape(Circle()).position(d)
                    .gesture(drag(sp, source: false))
                    .onTapGesture { model.selectedHealID = sp.id }
            }
        }
    }

    func drag(_ sp: HealSpot, source: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("maskcanvas"))
            .onChanged { g in
                model.selectedHealID = sp.id
                if start == nil { start = source ? (sp.srcX, sp.srcY) : (sp.x, sp.y) }
                guard let st = start else { return }
                let nx = min(max(st.0 + Double(g.translation.width / rect.width), 0), 1)
                let ny = min(max(st.1 + Double(g.translation.height / rect.height), 0), 1)
                model.updateHeal { h in
                    if source { h.srcX = nx; h.srcY = ny } else {
                        let dx = nx - h.x, dy = ny - h.y
                        h.x = nx; h.y = ny; h.srcX += dx; h.srcY += dy
                    }
                }
            }
            .onEnded { _ in start = nil; model.refreshHealShift(); model.commit() }
    }
}
