import SwiftUI

struct ContentView: View {
    @State private var controller = TunnelController()
    @State private var selection: TunnelServer.ID?

    var body: some View {
#if os(macOS)
        NavigationSplitView {
            ServerListView(controller: controller, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                .navigationTitle("Waypo")
        } detail: {
            ConnectionCard(controller: controller)
        }
#else
        ServerListView(controller: controller, selection: $selection, showsConnectionRow: true)
            .navigationTitle("Waypo")
#endif
        .task { await controller.refresh() }
    }
}
