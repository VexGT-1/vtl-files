import SwiftUI

@main
struct VTLFilesApp: App {
    init() {
        // Grant broad sandbox access on launch so FileManager calls succeed
        // without per-directory fallback overhead.
        Task.detached(priority: .userInitiated) {
            grantBroadAccess()
        }
    }

    var body: some Scene {
        WindowGroup {
            FileBrowserView()
        }
    }
}
