import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case profiles = "Looks", crop = "Crop", light = "Light", color = "Color", effects = "Effects",
         detail = "Detail", optics = "Optics", geometry = "Geometry"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .profiles: return "square.stack.3d.up"
        case .crop: return "crop.rotate"
        case .light: return "sun.max"
        case .color: return "thermometer.medium"
        case .effects: return "sparkles"
        case .detail: return "triangle"
        case .optics: return "camera.aperture"
        case .geometry: return "perspective"
        }
    }
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

    init(item: PhotoItem) { _model = StateObject(wrappedValue: EditorModel(item: item)) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            imageArea
            panel
                .frame(height: 290)
                .background(Theme.panel)
            toolBar
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: tool) { _, t in model.cropMode = (t == .crop); zoom = 1; pan = .zero }
        .sheet(isPresented: $showExport) { ExportSheet(model: model).presentationDetents([.medium, .large]) }
    }

    // MARK: Top bar

    var topBar: some View {
        HStack(spacing: 18) {
            Button { model.finish(); dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)) }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo)
            Button { showHistogram.toggle() } label: { Image(systemName: "chart.bar.xaxis") }
            Image(systemName: "square.split.2x1")
                .foregroundStyle(showOriginal ? Theme.accent : .primary)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !showOriginal { model.loadOriginal(); showOriginal = true } }
                    .onEnded { _ in showOriginal = false })
            Menu {
                Button { LibraryStore.shared.clipboard = model.settings } label: { Label("Copy Settings", systemImage: "doc.on.doc") }
                if let c = LibraryStore.shared.clipboard {
                    Button { model.edit { s in
                        let keep = s; s = c
                        s.crop = keep.crop; s.straighten = keep.straighten; s.rotation90 = keep.rotation90; s.lensProfileID = keep.lensProfileID
                    } } label: { Label("Paste Settings", systemImage: "doc.on.clipboard") }
                }
                Button(role: .destructive) { model.reset() } label: { Label("Reset All", systemImage: "arrow.counterclockwise") }
            } label: { Image(systemName: "ellipsis.circle") }
            Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Image

    var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = (showOriginal ? (model.original ?? model.preview) : model.preview) {
                    if tool == .crop {
                        CropOverlay(model: model, image: img, container: geo.size)
                    } else {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .scaleEffect(zoom)
                            .offset(pan)
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
                    }
                } else {
                    ProgressView()
                }
                if showOriginal {
                    Text("Original").font(.caption.weight(.semibold)).padding(6).background(.black.opacity(0.6), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top).padding(8)
                }
                if showHistogram && tool != .crop && !model.histogram.isEmpty {
                    HistogramView(data: model.histogram)
                        .frame(width: 130, height: 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
    }

    // MARK: Panel

    @ViewBuilder var panel: some View {
        switch tool {
        case .profiles: ProfilesPanel(model: model)
        case .crop: CropPanel(model: model)
        case .light: LightPanel(model: model)
        case .color: ColorPanel(model: model)
        case .effects: EffectsPanel(model: model)
        case .detail: DetailPanel(model: model)
        case .optics: OpticsPanel(model: model)
        case .geometry: GeometryPanel(model: model)
        }
    }

    var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(EditorTool.allCases) { t in
                    Button { tool = t } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.icon).font(.system(size: 19))
                            Text(t.rawValue).font(.system(size: 10, weight: .medium))
                        }
                        .frame(width: 64, height: 50)
                        .foregroundStyle(tool == t ? Theme.accent : .white)
                    }
                }
            }.padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .background(Color(white: 0.05))
    }
}
