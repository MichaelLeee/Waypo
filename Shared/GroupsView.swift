import SwiftUI

/// Lists the profile's server groups. Select groups switch members on tap;
/// url-test groups show the member the engine currently routes through.
struct GroupsView: View {
    var controller: TunnelController

    @Environment(\.dismiss) private var dismiss
    @State private var editingGroup: PolicyGroup?
    @State private var showingNewGroup = false

    var body: some View {
        NavigationStack {
            Group {
                if controller.configuration.groups.isEmpty {
                    ContentUnavailableView(
                        "No Groups",
                        systemImage: "rectangle.stack",
                        description: Text("Group servers to switch between them in one tap, or to test them automatically.")
                    )
                } else {
                    groupsList
                }
            }
            .navigationTitle("Groups")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewGroup = true
                    } label: {
                        Label("Add Group", systemImage: "plus")
                    }
                    .disabled(controller.configuration.servers.isEmpty)
                }
            }
            .sheet(item: $editingGroup) { group in
                GroupEditorView(controller: controller, mode: .edit(group))
            }
            .sheet(isPresented: $showingNewGroup) {
                GroupEditorView(controller: controller, mode: .new)
            }
        }
    }

    private var groupsList: some View {
        List {
            ForEach(controller.configuration.groups) { group in
                Section {
                    ForEach(members(of: group), id: \.server.id) { entry in
                        MemberRow(
                            server: entry.server,
                            latencyMs: entry.latencyMs,
                            isSelected: entry.isSelected,
                            canSelect: group.kind == .select
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard group.kind == .select else { return }
                            controller.setGroupMember(group: group.id, member: entry.server.id)
                        }
                    }
                } header: {
                    HStack {
                        Text(group.name)
                        Spacer()
                        Text(group.kind == .urlTest ? "URL Test" : "Select")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let deletable = controller.configuration.groups
                for offset in offsets where offset < deletable.count {
                    controller.deleteGroup(deletable[offset].id)
                }
            }
        }
    }

    private struct MemberEntry {
        var server: TunnelServer
        var latencyMs: Int?
        var isSelected: Bool
    }

    private func members(of group: PolicyGroup) -> [MemberEntry] {
        let state = controller.groupState(for: group.id)
        return group.memberIDs.compactMap { memberID in
            guard let server = controller.configuration.servers.first(where: { $0.id == memberID }) else {
                return nil
            }
            let engineLatency = state?.members.first { $0.tag == memberID.uuidString }?.latencyMs
            let fallbackLatency = controller.latencies[memberID]
            let latencyMs = engineLatency ?? fallbackLatency.map { Int($0) }
            let isSelected = group.kind == .select
                ? state?.selected == memberID.uuidString || (state == nil && group.memberIDs.first == memberID)
                : state?.selected == memberID.uuidString
            return MemberEntry(server: server, latencyMs: latencyMs, isSelected: isSelected)
        }
    }
}

private struct MemberRow: View {
    var server: TunnelServer
    var latencyMs: Int?
    var isSelected: Bool
    var canSelect: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .foregroundStyle(canSelect ? .primary : .secondary)
                Text("\(server.host):\(server.port)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let latencyMs {
                Text("\(latencyMs) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(latencyColor(latencyMs))
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 150 { return .green }
        if latency < 400 { return .orange }
        return .red
    }
}

/// Creates or edits a group: name, kind, re-test settings, and membership.
struct GroupEditorView: View {
    enum Mode {
        case new
        case edit(PolicyGroup)
    }

    var controller: TunnelController
    var mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: PolicyGroupKind = .select
    @State private var interval: TimeInterval = 300
    @State private var selectedMembers: Set<TunnelServer.ID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Kind", selection: $kind) {
                        Text("Select").tag(PolicyGroupKind.select)
                        Text("URL Test").tag(PolicyGroupKind.urlTest)
                    }
                    if kind == .urlTest {
                        Picker("Re-test Every", selection: $interval) {
                            Text("30 seconds").tag(TimeInterval(30))
                            Text("1 minute").tag(TimeInterval(60))
                            Text("3 minutes").tag(TimeInterval(180))
                            Text("5 minutes").tag(TimeInterval(300))
                            Text("10 minutes").tag(TimeInterval(600))
                        }
                    }
                } footer: {
                    Text(kind == .urlTest
                         ? "The engine keeps testing every member and uses the fastest one."
                         : "Tap a member in the group list to route through it.")
                }

                Section("Members") {
                    if controller.configuration.servers.isEmpty {
                        Text("Add servers first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.configuration.servers) { server in
                            Button {
                                toggle(server.id)
                            } label: {
                                HStack {
                                    Text(server.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedMembers.contains(server.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Group" : "Edit Group")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || selectedMembers.isEmpty)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private func load() {
        guard case .edit(let group) = mode else { return }
        name = group.name
        kind = group.kind
        interval = group.interval
        selectedMembers = Set(group.memberIDs)
    }

    private func toggle(_ id: TunnelServer.ID) {
        if selectedMembers.contains(id) {
            selectedMembers.remove(id)
        } else {
            selectedMembers.insert(id)
        }
    }

    private func save() {
        // Keep the previous order of existing members, then append new ones
        // in server-list order.
        var memberIDs: [TunnelServer.ID] = []
        if case .edit(let group) = mode {
            memberIDs = group.memberIDs.filter { selectedMembers.contains($0) }
        }
        for server in controller.configuration.servers
        where selectedMembers.contains(server.id) && !memberIDs.contains(server.id) {
            memberIDs.append(server.id)
        }

        switch mode {
        case .new:
            controller.addGroup(PolicyGroup(name: name.trimmingCharacters(in: .whitespaces),
                                            kind: kind, memberIDs: memberIDs,
                                            url: "https://www.gstatic.com/generate_204",
                                            interval: interval))
        case .edit(let group):
            var updated = group
            updated.name = name.trimmingCharacters(in: .whitespaces)
            updated.kind = kind
            updated.memberIDs = memberIDs
            updated.interval = interval
            controller.updateGroup(updated)
        }
        dismiss()
    }
}
