import SwiftUI

struct ServerListView: View {
    var controller: TunnelController
    @Binding var selection: TunnelServer.ID?
    var showsConnectionRow = false

    @State private var editingServer: TunnelServer?
    @State private var showingNewServer = false

    var body: some View {
        Group {
#if os(macOS)
            list
#else
            NavigationStack { list }
#endif
        }
        .sheet(item: $editingServer) { server in
            ServerEditorView(controller: controller, mode: .edit(server))
        }
        .sheet(isPresented: $showingNewServer) {
            ServerEditorView(controller: controller, mode: .new)
        }
        .overlay {
            if controller.configuration.servers.isEmpty {
                ContentUnavailableView(
                    "No Servers",
                    systemImage: "server.rack",
                    description: Text("Add a server to get started.")
                )
            }
        }
    }

    private var list: some View {
#if os(macOS)
        List(selection: $selection) {
            rows
        }
        .toolbar { toolbarContent }
#else
        List {
            if showsConnectionRow {
                Section("Tunnel") {
                    ConnectionStatusRow(controller: controller)
                    if let error = controller.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section("Servers") {
                rows
            }
        }
        .toolbar { toolbarContent }
#endif
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(controller.configuration.servers, id: \.id) { server in
            ServerRow(server: server, isActive: controller.isActiveServer(server.id))
#if os(macOS)
                .tag(server.id)
                .contextMenu {
                    rowMenu(server)
                }
#else
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        controller.deleteServer(server.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        controller.setActiveServer(server.id)
                    } label: {
                        Label("Activate", systemImage: "checkmark.circle")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    rowMenu(server)
                }
#endif
        }
    }

    @ViewBuilder
    private func rowMenu(_ server: TunnelServer) -> some View {
        Button("Set as Active") {
            controller.setActiveServer(server.id)
        }
        Button("Edit…") {
            editingServer = server
        }
        Divider()
        Button("Delete", role: .destructive) {
            controller.deleteServer(server.id)
        }
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showingNewServer = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            Button {
                if let id = selection,
                   let server = controller.configuration.servers.first(where: { $0.id == id }) {
                    editingServer = server
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(selection == nil)
        }
    }
}

struct ServerRow: View {
    var server: TunnelServer
    var isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text("\(server.host):\(server.port)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("In Use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
    }
}
