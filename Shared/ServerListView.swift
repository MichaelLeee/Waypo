import SwiftUI

struct ServerListView: View {
    var controller: TunnelController
    var service: ScriptService
    @Binding var selection: TunnelServer.ID?
    var showsConnectionRow = false

    @State private var editingServer: TunnelServer?
    @State private var showingNewServer = false
    @State private var showingImport = false
    @State private var showingLogs = false
    @State private var showingGroups = false
    @State private var showingConnections = false
    @State private var showingDNS = false
    @State private var showingRules = false
    @State private var showingScripts = false
    @State private var showingNewProfile = false
    @State private var newProfileName = ""
#if os(macOS)
    @State private var systemMode = SystemModeController()
#endif

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
        .sheet(isPresented: $showingGroups) {
            GroupsView(controller: controller)
        }
        .sheet(isPresented: $showingConnections) {
            ConnectionsView(controller: controller)
        }
        .sheet(isPresented: $showingDNS) {
            DNSSettingsView(controller: controller)
        }
        .sheet(isPresented: $showingRules) {
            RulesView(controller: controller)
        }
        .sheet(isPresented: $showingScripts) {
            ScriptListView(service: service)
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
    }

    private var list: some View {
        content
#if os(macOS)
            .toolbar { profileToolbar; systemModeToolbar; toolbarContent }
#else
            .navigationTitle("Servers")
            .toolbar { profileToolbar; toolbarContent }
#endif
            .inlineTitleOnIOS()
    }

    @ViewBuilder
    private var content: some View {
        if controller.configuration.servers.isEmpty {
            WaypoEmptyState("No Servers",
                            systemImage: "server.rack",
                            message: "Add a server to get started.")
        } else {
#if os(macOS)
            List(selection: $selection) {
                rows
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                systemModeFooter
            }
#else
            List {
                if showsConnectionRow {
                    Section("Tunnel") {
                        ConnectionStatusRow(controller: controller)
                        if let error = controller.lastError {
                            ErrorText(error, alignment: .leading)
                        }
                    }
                }
                Section("Servers") {
                    rows
                }
            }
#endif
        }
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

#if os(macOS)
    private var systemModeToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                systemMode.toggle(configuration: controller.configuration)
            } label: {
                if systemMode.isRunning {
                    Label("Stop System Mode", systemImage: "stop.circle")
                } else {
                    Label("System Mode", systemImage: "globe")
                }
            }
            .disabled(systemMode.isBusy || controller.configuration.servers.isEmpty)
        }
    }

    @ViewBuilder
    private var systemModeFooter: some View {
        if let error = systemMode.lastError {
            ErrorText(error, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
        } else if systemMode.isRunning {
            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.positive)
                    .frame(width: 7, height: 7)
                Text("System Mode active · port \(SystemModeController.listenerPort)")
                Spacer()
                if let traffic = systemMode.traffic {
                    Text("\(byteCount(traffic.bytesIn)) in · \(byteCount(traffic.bytesOut)) out · \(traffic.activeConnections) connections")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.neutral)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
#endif

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
#if os(macOS)
            // Nine buttons do not fit a window toolbar, so the panel screens
            // live behind one menu.
            Menu {
                panelsMenuItems
            } label: {
                Label("Panels", systemImage: "ellipsis.circle")
            }
#else
            Button {
                showingGroups = true
            } label: {
                Label("Groups", systemImage: "rectangle.stack")
            }
            Button {
                showingConnections = true
            } label: {
                Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Button {
                showingDNS = true
            } label: {
                Label("DNS", systemImage: "arrow.triangle.branch")
            }
            Button {
                showingRules = true
            } label: {
                Label("Rules", systemImage: "arrow.3.trianglepath")
            }
            Button {
                showingLogs = true
            } label: {
                Label("Engine Logs", systemImage: "doc.text")
            }
            Button {
                showingScripts = true
            } label: {
                Label("Scripts", systemImage: "curlybraces")
            }
#endif
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

    @ViewBuilder
    private var panelsMenuItems: some View {
        Button {
            showingGroups = true
        } label: {
            Label("Groups", systemImage: "rectangle.stack")
        }
        Button {
            showingConnections = true
        } label: {
            Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
        }
        Button {
            showingDNS = true
        } label: {
            Label("DNS", systemImage: "arrow.triangle.branch")
        }
        Button {
            showingRules = true
        } label: {
            Label("Rules", systemImage: "arrow.3.trianglepath")
        }
        Button {
            showingLogs = true
        } label: {
            Label("Engine Logs", systemImage: "doc.text")
        }
        Button {
            showingScripts = true
        } label: {
            Label("Scripts", systemImage: "curlybraces")
        }
    }
}

struct ServerRow: View {
    var server: TunnelServer
    var isActive: Bool
    var latency: Double?

    @ScaledMetric(relativeTo: .body) private var iconSize = Metrics.rowIconSize

    var body: some View {
        HStack(spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text("\(server.host):\(server.port)")
                    .font(.footnote)
                    .foregroundStyle(Palette.neutral)
            }
            Spacer()
            if let latency {
                Text(LatencyLevel.label(milliseconds: latency))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LatencyLevel(milliseconds: latency).color)
                    .contentTransition(.numericText())
                    .animation(.default, value: latency)
            }
            if isActive {
                StatusPill("In Use", tone: .positive)
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if let custom = server.icon?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            Text(custom)
                .font(.title3)
                .frame(width: iconSize)
        } else {
            Image(systemName: TransportStyle.symbol(for: server.transport))
                .foregroundStyle(Palette.accent)
                .frame(width: iconSize)
        }
    }
}
