import SwiftUI

@main
struct LumoraApp: App {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var cloud = CloudSync.shared

    init() {
        // Warm up the lens database in the background so Optics opens instantly.
        DispatchQueue.global(qos: .background).async {
            LensDatabase.shared.loadIfNeeded()
            _ = ClipTokenizer.shared
        }
        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(red: 0.22, green: 0.22, blue: 0.26, alpha: 1)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(cloud)
                .environmentObject(SmartSort.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.56, blue: 0.30)         // sunset orange (from the icon)
    static let accent2 = Color(red: 1.0, green: 0.80, blue: 0.45)
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let panel = Color(red: 0.075, green: 0.075, blue: 0.09)
    static let panel2 = Color(red: 0.13, green: 0.13, blue: 0.155)
    static let stroke = Color.white.opacity(0.08)
    static let text2 = Color(white: 0.58)
    static let gradient = LinearGradient(colors: [accent2, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
}
