import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var cloud: CloudSync
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
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("Lens profiles come from the Lensfun database (lensfun.github.io), licensed CC BY-SA 3.0.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $pickFolder) {
                FolderPicker { url in cloud.setFolder(url) }.ignoresSafeArea()
            }
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
