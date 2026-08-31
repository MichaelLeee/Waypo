import SwiftUI

struct ServerListView: View {
    var controller: TunnelController
    @Binding var selection: TunnelServer.ID?
    var showsConnectionRow = false

    @State private var editingServer: TunnelServer?
    @State private var showingNewServer = false
    @State private var showingImport = false
    @State private var showingLogs = false
    @State private var showingNewProfile = false
    @State private var newProfileName = ""

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
        .sheet(isPresented: $showingImport) {
            ImportView(controller: controller)
        }
        .sheet(isPresented: $showingLogs) {
            LogView(controller: controller)
        }
        .alert("New Profile", isPresented: $showingNewProfile) {
            TextField("Name", text: $newProfileName)
            Button("Create") {
                controller.addProfile(named: newProfileName)
                newProfileName = ""
            }
            Button("Cancel", role: .cancel) { newProfileName = "" }
        } message: {
            Text("Each profile has its own server list.")
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
        .toolbar { profileToolbar; toolbarContent }
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
        .toolbar { profileToolbar; toolbarContent }
#endif
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(controller.configuration.servers, id: \.id) { server in
            ServerRow(
                server: server,
                isActive: controller.isActiveServer(server.id),
                latency: controller.latencies[server.id]
            )
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
        Button {
            Task { await controller.checkLatency(for: server.id) }
        } label: {
            Label("Test Latency", systemImage: "antenna.radiowaves.left.and.right")
        }
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

    private var profileToolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                ForEach(controller.profiles) { profile in
                    Button {
                        controller.switchProfile(to: profile.id)
                    } label: {
                        if profile.id == controller.activeProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
                Divider()
                Button {
                    showingNewProfile = true
                } label: {
                    Label("New Profile…", systemImage: "plus")
                }
                if controller.profiles.count > 1 {
                    Button(role: .destructive) {
                        controller.deleteActiveProfile()
                    } label: {
                        Label("Delete Active Profile", systemImage: "trash")
                    }
                }
            } label: {
                Label(controller.activeProfile?.name ?? "Profile", systemImage: "square.stack.3d.up")
            }
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
                showingImport = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            Button {
                showingLogs = true
            } label: {
                Label("Engine Logs", systemImage: "doc.text")
            }
            Button {
                Task { await controller.checkAllLatencies() }
            } label: {
                Label("Test Latency", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(controller.isTestingLatency)
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
    var latency: Double?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text("\(server.host):\(server.port)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let latency {
                Text(String(format: "%.0f ms", latency))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(latencyColor(latency))
            }
            if isActive {
                Text("In Use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
    }

    private func latencyColor(_ latency: Double) -> Color {
        if latency < 150 { return .green }
        if latency < 400 { return .orange }
        return .red
    }
}
