import SwiftUI

@main
struct WaypoMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 420, minHeight: 320)
        }
        .windowResizability(.contentMinSize)
    }
}
