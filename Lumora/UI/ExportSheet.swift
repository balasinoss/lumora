import SwiftUI
import Photos

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.dismiss) var dismiss
    @State private var format: RenderPipeline.ExportFormat = .jpeg
    @State private var quality: Double = 0.92
    @State private var size = 0
    @State private var working = false
    @State private var message: String?
    @State private var shareURL: URL?

    var maxEdge: CGFloat? { [nil, 4096, 2048, 1080][size] }

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    Picker("Format", selection: $format) { ForEach(RenderPipeline.ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
                    if format != .png {
                        VStack(alignment: .leading) {
                            Text("Quality \(Int(quality * 100))")
                            Slider(value: $quality, in: 0.5...1)
                        }
                    }
                    Picker("Size", selection: $size) {
                        Text("Full size").tag(0); Text("4096 px").tag(1); Text("2048 px").tag(2); Text("1080 px").tag(3)
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
                if working { HStack { ProgressView(); Text("Rendering full resolution…") } }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.text2) }
            }
            .navigationTitle("Export").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        }
    }

    func run(_ then: @escaping (URL) -> Void) {
        working = true; message = nil
        model.export(format: format, quality: quality, maxLongEdge: maxEdge) { url in
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
