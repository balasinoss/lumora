import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var cloud: CloudSync
    @EnvironmentObject var smart: SmartSort
    @State private var newName = ""
    @State private var newPrompt = ""
    @Environment(\.dismiss) var dismiss
    @State private var pickFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let name = cloud.folderName {
                        Label("Saving to “\(name)”", systemImage: "checkmark.icloud.fill").foregroundStyle(.green)
                        Button("Change Folder") { pickFolder = true }
                        Button("Restore Photos From Folder") { cloud.restore() }
                        Button("Disconnect", role: .destructive) { cloud.disconnect() }
                    } else {
                        Button {
                            pickFolder = true
                        } label: { Label("Choose iCloud Drive Folder", systemImage: "icloud") }
                    }
                    if !cloud.lastStatus.isEmpty {
                        Text(cloud.lastStatus).font(.footnote).foregroundStyle(Theme.text2)
                    }
                } header: { Text("iCloud Drive") } footer: {
                    Text("Tip: in the picker open iCloud Drive, tap the folder icon to create a folder called “Lumora”, open it and tap Open. Lumora then saves automatically — your originals and edits (so you can restore them on any iPhone) and finished JPEGs in an “Edited” folder you can open from Files or iCloud.com.")
                }
                Section("Automatic Saving") {
                    Toggle("Save edited JPEGs automatically", isOn: $cloud.autoExport)
                    Toggle("Back up original photos", isOn: $cloud.backupOriginals)
                    VStack(alignment: .leading) {
                        Text("JPEG quality \(Int(cloud.exportQuality * 100))")
                        Slider(value: $cloud.exportQuality, in: 0.6...1.0, step: 0.01)
                    }
                }
                Section {
                    Toggle("Sort new photos automatically", isOn: $smart.autoAnalyze).tint(Theme.accent)
                    threshold("In Focus — minimum sharpness", $smart.focusThreshold)
                    threshold("Sharpest — minimum sharpness", $smart.sharpThreshold)
                    threshold("Blurry — below", $smart.blurThreshold)
                    VStack(alignment: .leading) {
                        Text("AI album confidence: \(smart.strictness < 0.34 ? "Relaxed" : smart.strictness < 0.67 ? "Balanced" : "Strict")")
                        Slider(value: $smart.strictness, in: 0...1).tint(Theme.accent)
                    }
                    Button("Re-analyze all photos") { smart.enqueue(LibraryStore.shared.items, force: true) }
                } header: { Text("Smart Albums") } footer: {
                    Text("Sharpness is measured on the main subject (0–100). Tip: sort the library by sharpness to see the numbers for your camera, then tune these. A photo can be in several albums at once — nothing is copied.")
                }
                Section("Albums") {
                    ForEach($smart.categories) { $c in
                        HStack {
                            Image(systemName: c.icon).frame(width: 24).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading) {
                                Text(c.name)
                                if !c.isMetric && !c.builtIn {
                                    Text(c.prompts.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.text2).lineLimit(1)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: $c.enabled).labelsHidden().tint(Theme.accent)
                        }
                    }
                    .onDelete { idx in
                        let removable = idx.filter { !smart.categories[$0].builtIn }
                        smart.categories.remove(atOffsets: IndexSet(removable))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add your own album").font(.subheadline.bold())
                        TextField("Name (e.g. Free Throws)", text: $newName)
                        TextField("Describe the photos (e.g. a player shooting a free throw)", text: $newPrompt, axis: .vertical)
                        Button("Add Album") {
                            let id = "custom-" + UUID().uuidString.prefix(8)
                            smart.categories.append(SmartCategory(id: String(id), name: newName, icon: "sparkles",
                                                                  prompts: [newPrompt], builtIn: false))
                            newName = ""; newPrompt = ""
                            smart.rescoreAll()
                        }
                        .disabled(newName.isEmpty || newPrompt.count < 4)
                    }
                    .padding(.vertical, 4)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("Lens profiles: Lensfun database (CC BY-SA 3.0). AI Denoise: DRUNet (KAIR, MIT). Sky masks: SegFormer (NVIDIA). Smart albums: MobileCLIP (Apple). Subject & people masks: Apple Vision.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $pickFolder) {
                FolderPicker { url in cloud.setFolder(url) }.ignoresSafeArea()
            }
        }
    }
}

extension SettingsView {
    func threshold(_ title: String, _ v: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(v.wrappedValue))")
            Slider(value: v, in: 0...100, step: 1).tint(Theme.accent)
        }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ f: @escaping (URL) -> Void) { onPick = f }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}
