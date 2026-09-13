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
                    WaypoEmptyState(
                        "No Groups",
                        systemImage: "rectangle.stack",
                        message: "Group servers to switch between them in one tap, or to test them automatically."
                    )
                } else {
                    groupsList
                }
            }
            .navigationTitle("Groups")
            .inlineTitleOnIOS()
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
                    .disabled(controller.configuration.servers.isEmpty
                              && controller.configuration.groups.isEmpty)
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
                    ForEach(members(of: group)) { entry in
                        MemberRow(entry: entry, canSelect: group.kind == .select)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard group.kind == .select else { return }
                                controller.setGroupMember(group: group.id, member: entry.id)
                            }
                    }
                } header: {
                    GroupHeaderRow(title: group.name,
                                   detail: group.kind == .urlTest ? "URL Test" : "Select")
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

    /// Members resolve against servers first and groups second, so a group
    /// whose member is another group is listed rather than silently missing.
    /// Both kinds share one id space: a member is one or the other, never both.
    private func members(of group: PolicyGroup) -> [MemberEntry] {
        let state = controller.groupState(for: group.id)
        return group.memberIDs.compactMap { memberID in
            if let server = controller.configuration.servers.first(where: { $0.id == memberID }) {
                return entry(id: memberID,
                             name: server.name,
                             detail: "\(server.host):\(server.port)",
                             isGroup: false,
                             group: group,
                             state: state)
            }
            if let nested = controller.configuration.groups.first(where: { $0.id == memberID }) {
                return entry(id: memberID,
                             name: nested.name,
                             detail: nil,
                             isGroup: true,
                             group: group,
                             state: state)
            }
            return nil
        }
    }

    private func entry(id: UUID,
                       name: String,
                       detail: String?,
                       isGroup: Bool,
                       group: PolicyGroup,
                       state: PolicyGroupState?) -> MemberEntry {
        let engineLatency = state?.members.first { $0.tag == id.uuidString }?.latencyMs
        let fallbackLatency = controller.latencies[id]
        let isSelected = group.kind == .select
            ? state?.selected == id.uuidString || (state == nil && group.memberIDs.first == id)
            : state?.selected == id.uuidString
        return MemberEntry(id: id,
                           name: name,
                           detail: detail,
                           isGroup: isGroup,
                           latencyMs: engineLatency ?? fallbackLatency.map { Int($0) },
                           isSelected: isSelected)
    }
}

private struct MemberEntry: Identifiable {
    var id: UUID
    var name: String
    /// The address line under the name; a group member has none.
    var detail: String?
    var isGroup: Bool
    var latencyMs: Int?
    var isSelected: Bool
}

private struct MemberRow: View {
    var entry: MemberEntry
    var canSelect: Bool

    var body: some View {
        HStack {
            if entry.isGroup {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .foregroundStyle(canSelect ? .primary : .secondary)
                Text(entry.detail ?? "Group")
                    .font(.footnote)
                    .foregroundStyle(Palette.neutral)
            }
            Spacer()
            if let latencyMs = entry.latencyMs {
                Text(LatencyLevel.label(milliseconds: Double(latencyMs)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LatencyLevel(milliseconds: Double(latencyMs)).color)
                    .contentTransition(.numericText())
                    .animation(.default, value: latencyMs)
            }
            if entry.isSelected {
                StatusPill(systemImage: "checkmark.circle.fill", tone: .positive)
            }
        }
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

                Section {
                    if controller.configuration.servers.isEmpty && memberCandidates.isEmpty {
                        Text("Add servers first.")
                            .foregroundStyle(Palette.neutral)
                    } else {
                        ForEach(controller.configuration.servers) { server in
                            candidateRow(id: server.id, name: server.name, symbol: nil)
                        }
                        ForEach(memberCandidates) { group in
                            candidateRow(id: group.id,
                                         name: group.name,
                                         symbol: "rectangle.stack")
                        }
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("A member can be another group, so one group can switch between whole sets of servers. A group cannot contain itself.")
                }
            }
            .navigationTitle(isNew ? "New Group" : "Edit Group")
            .inlineTitleOnIOS()
            .editorToolbar(isSaveDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty
                           || selectedMembers.isEmpty) { save() }
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

    private func candidateRow(id: UUID, name: String, symbol: String?) -> some View {
        Button {
            toggle(id)
        } label: {
            HStack {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(Palette.accent)
                }
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedMembers.contains(id) {
                    StatusPill(systemImage: "checkmark", tone: .accent)
                }
            }
        }
    }

    private var editingID: UUID? {
        if case .edit(let group) = mode { return group.id }
        return nil
    }

    /// The groups this one may contain: every group but itself and anything
    /// already reachable from it, which is what keeps membership acyclic.
    private var memberCandidates: [PolicyGroup] {
        let reachable = descendants(of: editingID)
        return controller.configuration.groups.filter {
            $0.id != editingID && !reachable.contains($0.id)
        }
    }

    /// Every group id reachable by following member links down from `id`.
    private func descendants(of id: UUID?) -> Set<UUID> {
        guard let id else { return [] }
        var seen: Set<UUID> = []
        var pending = [id]
        while let next = pending.popLast() {
            guard let group = controller.configuration.groups.first(where: { $0.id == next })
            else { continue }
            for member in group.memberIDs where !seen.contains(member) {
                seen.insert(member)
                pending.append(member)
            }
        }
        return seen
    }

    private func save() {
        // Keep the previous order of existing members, then append the newly
        // selected ones: servers first, then groups, each in list order.
        var memberIDs: [TunnelServer.ID] = []
        if case .edit(let group) = mode {
            memberIDs = group.memberIDs.filter { selectedMembers.contains($0) }
        }
        for server in controller.configuration.servers
        where selectedMembers.contains(server.id) && !memberIDs.contains(server.id) {
            memberIDs.append(server.id)
        }
        for group in memberCandidates
        where selectedMembers.contains(group.id) && !memberIDs.contains(group.id) {
            memberIDs.append(group.id)
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
