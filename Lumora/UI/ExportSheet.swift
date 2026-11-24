import SwiftUI
import Photos
import PhotosUI

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.dismiss) var dismiss
    @State private var format: RenderPipeline.ExportFormat = .jpeg
    @State private var quality: Double = 0.92
    @State private var size = 0
    @State private var layout = ExportLayout.saved
    @State private var upscale = 1
    @State private var working = false
    @State private var message: String?
    @State private var shareURL: URL?
    @State private var logoItem: PhotosPickerItem?

    var maxEdge: CGFloat? { layout.frame != .original ? nil : [nil, 4096, 2048, 1080][size] }
    var maxUpscale: Int { model.source.map { Upscaler.maxFactor(for: $0.fullSize) } ?? 1 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Size") {
                    Picker("Frame", selection: $layout.frame) { ForEach(ExportLayout.Frame.allCases) { Text($0.rawValue).tag($0) } }
                    if layout.frame != .original {
                        Picker("Fit", selection: $layout.fit) { ForEach(ExportLayout.Fit.allCases) { Text($0.rawValue).tag($0) } }
                    } else {
                        Picker("Long edge", selection: $size) {
                            Text("Full size").tag(0); Text("4096 px").tag(1); Text("2048 px").tag(2); Text("1080 px").tag(3)
                        }
                    }
                    Picker("AI Upscale", selection: $upscale) {
                        Text("Off").tag(1)
                        if maxUpscale >= 2 { Text("2× (sharper crops)").tag(2) }
                        if maxUpscale >= 4 { Text("4×").tag(4) }
                    }
                }
                Section("File") {
                    Picker("Format", selection: $format) { ForEach(RenderPipeline.ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
                    if format != .png {
                        VStack(alignment: .leading) {
                            Text("Quality \(Int(quality * 100))")
                            Slider(value: $quality, in: 0.5...1).tint(Theme.accent)
                        }
                    }
                }
                Section("Watermark") {
                    Toggle("Add watermark", isOn: $layout.watermark).tint(Theme.accent)
                    if layout.watermark {
                        Toggle("Use logo image", isOn: $layout.useLogo).tint(Theme.accent)
                        if layout.useLogo {
                            PhotosPicker(selection: $logoItem, matching: .images) { Label("Choose logo (PNG with transparency)", systemImage: "photo") }
                        } else {
                            TextField("Text (e.g. @yourname)", text: $layout.watermarkText)
                        }
                        Picker("Position", selection: $layout.corner) { ForEach(ExportLayout.Corner.allCases) { Text($0.rawValue).tag($0) } }
                        VStack(alignment: .leading) {
                            Text("Size")
                            Slider(value: $layout.size, in: 0.015...0.08).tint(Theme.accent)
                        }
                        VStack(alignment: .leading) {
                            Text("Opacity \(Int(layout.opacity * 100))%")
                            Slider(value: $layout.opacity, in: 0.2...1).tint(Theme.accent)
                        }
                    }
                }
                Section {
                    Button { run { url in saveToPhotos(url) } } label: { Label("Save to Photos", systemImage: "photo.badge.arrow.down") }
                    Button { run { url in shareURL = url } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                    if cloud.isConfigured {
                        Button {
                            model.finish(); message = "Saving to \(cloud.folderName ?? "iCloud Drive")…"
                        } label: { Label("Save to iCloud Drive now", systemImage: "icloud.and.arrow.up") }
                    }
                }
                if working {
                    HStack {
                        ProgressView(value: model.exportProgress)
                        Text(model.exportProgress != nil ? "AI upscaling… \(Int((model.exportProgress ?? 0) * 100))%" : "Rendering full resolution…")
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.text2) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Export").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
            .onChange(of: layout) { _, l in ExportLayout.saved = l }
            .onChange(of: logoItem) { _, item in
                Task {
                    if let d = try? await item?.loadTransferable(type: Data.self) {
                        try? d.write(to: ExportLayout.logoURL, options: .atomic)
                        message = "Logo saved"
                    }
                }
            }
        }
    }

    func run(_ then: @escaping (URL) -> Void) {
        working = true; message = nil
        model.export(format: format, quality: quality, maxLongEdge: maxEdge, layout: layout, upscale: upscale) { url in
            working = false
            if let url { then(url) } else { message = "Export failed" }
        }
    }

    func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = "Allow Lumora to add photos in Settings → Privacy → Photos" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }) { ok, _ in
                DispatchQueue.main.async { message = ok ? "Saved to Photos ✓" : "Could not save to Photos" }
            }
        }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
