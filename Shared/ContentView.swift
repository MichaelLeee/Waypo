import SwiftUI

struct ContentView: View {
    @State private var controller: TunnelController
    @State private var service: ScriptService
    @State private var selection: TunnelServer.ID?
    @Environment(\.scenePhase) private var scenePhase

    /// Built here rather than as two property initializers because the service
    /// needs the controller: a server a script asks for goes through the same
    /// path as a tap in the list. Both live for the life of the window, so a
    /// schedule is never rebuilt under a running run.
    init() {
        let controller = TunnelController()
        _controller = State(initialValue: controller)
        _service = State(initialValue: ScriptService.live(controller: controller))
    }

    var body: some View {
        Group {
#if os(macOS)
            NavigationSplitView {
                ServerListView(controller: controller, service: service, selection: $selection)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    .navigationTitle("Waypo")
            } detail: {
                ConnectionCard(controller: controller)
            }
#else
            ServerListView(controller: controller, service: service, selection: $selection,
                           showsConnectionRow: true)
                .navigationTitle("Waypo")
#endif
        }
        .tint(Palette.accent)
        .task {
            await controller.refresh()
            service.bind(to: controller)
            service.start()
            // After `start()`, which is what loads the scripts.
            service.noteAppLaunched()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.noteAppForeground() }
        }
    }
}
