import SwiftUI

@main
struct LumoraApp: App {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var cloud = CloudSync.shared

    init() {
        // Warm up the lens database in the background so Optics opens instantly.
        DispatchQueue.global(qos: .background).async { LensDatabase.shared.loadIfNeeded() }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(cloud)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.35, green: 0.72, blue: 1.0)
    static let bg = Color(white: 0.07)
    static let panel = Color(white: 0.11)
    static let panel2 = Color(white: 0.16)
    static let text2 = Color(white: 0.62)
}
