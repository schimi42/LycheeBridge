import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
}

@main
struct LycheeBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
