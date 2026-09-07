import SwiftUI

/// Lists the profile's routing rules in evaluation order (first match wins)
/// and the remote rule-sets they can reference.
struct RulesView: View {
    var controller: TunnelController

    @Environment(\.dismiss) private var dismiss
    @State private var editingRule: RoutingRule?
    @State private var showingNewRule = false
    @State private var editingRuleSet: RemoteRuleSet?
    @State private var showingNewRuleSet = false

    private var rules: [RoutingRule] { controller.configuration.rules }
    private var ruleSets: [RemoteRuleSet] { controller.configuration.ruleSets }

    var body: some View {
        NavigationStack {
            Group {
                if rules.isEmpty && ruleSets.isEmpty {
                    ContentUnavailableView(
                        "No Rules",
                        systemImage: "arrow.triangle.branch",
                        description: Text("Route chosen traffic to a specific server, or block it outright.")
                    )
                } else {
                    lists
                }
            }
            .navigationTitle("Rules")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingNewRule = true
                        } label: {
                            Label("Add Rule", systemImage: "plus")
                        }
                        Button {
                            showingNewRuleSet = true
                        } label: {
                            Label("Add Rule Set", systemImage: "square.and.arrow.down.on.square")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editingRule) { rule in
                RuleEditorView(controller: controller, mode: .edit(rule))
            }
            .sheet(isPresented: $showingNewRule) {
                RuleEditorView(controller: controller, mode: .new)
            }
            .sheet(item: $editingRuleSet) { set in
                RuleSetEditorView(mode: .edit(set)) { updated in
                    var sets = ruleSets
                    sets[sets.firstIndex { $0.id == set.id }!] = updated
                    controller.updateRuleSets(sets)
                }
            }
            .sheet(isPresented: $showingNewRuleSet) {
                RuleSetEditorView(mode: .new) { set in
                    controller.updateRuleSets(ruleSets + [set])
                }
            }
        }
    }

    private var lists: some View {
        List {
            if !rules.isEmpty {
                Section {
                    ForEach(rules) { rule in
                        Button {
                            editingRule = rule
                        } label: {
                            RuleRow(rule: rule, controller: controller)
                        }
#if os(iOS)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                controller.moveRule(rule, up: true)
                            } label: {
                                Label("Move Up", systemImage: "arrow.up")
                            }
                            .tint(.blue)
                            .disabled(rule.id == rules.first?.id)
                            Button {
                                controller.moveRule(rule, up: false)
                            } label: {
                                Label("Move Down", systemImage: "arrow.down")
                            }
                            .tint(.blue)
                            .disabled(rule.id == rules.last?.id)
                        }
#endif
                        .contextMenu {
                            Button {
                                controller.moveRule(rule, up: true)
                            } label: {
                                Label("Move Up", systemImage: "arrow.up")
                            }
                            .disabled(rule.id == rules.first?.id)
                            Button {
                                controller.moveRule(rule, up: false)
                            } label: {
                                Label("Move Down", systemImage: "arrow.down")
                            }
                            .disabled(rule.id == rules.last?.id)
                            Divider()
                            Button("Delete", role: .destructive) {
                                controller.updateRules(rules.filter { $0.id != rule.id })
                            }
                        }
                    }
                    .onDelete { offsets in
                        var remaining = rules
                        remaining.remove(atOffsets: offsets)
                        controller.updateRules(remaining)
                    }
                } header: {
                    Text("Rules")
                } footer: {
                    Text("Evaluated top to bottom; the first match decides where traffic goes.")
                }
            }

            if !ruleSets.isEmpty {
                Section {
                    ForEach(ruleSets) { set in
                        Button {
                            editingRuleSet = set
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.name)
                                    .foregroundStyle(.primary)
                                Text(set.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { offsets in
                        var remaining = ruleSets
                        remaining.remove(atOffsets: offsets)
                        controller.updateRuleSets(remaining)
                    }
                } header: {
                    Text("Rule Sets")
                } footer: {
                    Text("Lists of domains or addresses kept current by the engine itself.")
                }
            }
        }
    }
}

private struct RuleRow: View {
    var rule: RoutingRule
    var controller: TunnelController

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(matchSummary)
                    .foregroundStyle(.primary)
                Text(actionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if rule.invert {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var matchSummary: String {
        var parts: [String] = []
        if !rule.domains.isEmpty { parts.append("\(rule.domains.count) domain\(rule.domains.count == 1 ? "" : "s")") }
        if !rule.domainSuffixes.isEmpty { parts.append("\(rule.domainSuffixes.count) suffix\(rule.domainSuffixes.count == 1 ? "" : "es")") }
        if !rule.domainKeywords.isEmpty { parts.append("\(rule.domainKeywords.count) keyword\(rule.domainKeywords.count == 1 ? "" : "s")") }
        if !rule.ipCIDRs.isEmpty { parts.append("\(rule.ipCIDRs.count) network\(rule.ipCIDRs.count == 1 ? "" : "s")") }
        if !rule.ports.isEmpty { parts.append("\(rule.ports.count) port\(rule.ports.count == 1 ? "" : "s")") }
        if !rule.ruleSetTags.isEmpty { parts.append("\(rule.ruleSetTags.count) set\(rule.ruleSetTags.count == 1 ? "" : "s")") }
        return (rule.invert ? "not " : "") + parts.joined(separator: ", ")
    }

    private var actionSummary: String {
        switch rule.action {
        case .route:
            let target: String
            if let id = rule.outboundID {
                if let group = controller.configuration.groups.first(where: { $0.id == id }) {
                    target = group.name
                } else if let server = controller.configuration.servers.first(where: { $0.id == id }) {
                    target = server.name
                } else {
                    target = "Unknown"
                }
            } else {
                target = "Active Selection"
            }
            return "Route via \(target)"
        case .reject:
            return "Reject"
        case .direct:
            return "Direct"
        }
    }
}

/// Creates or edits one routing rule: match criteria, action, and target.
struct RuleEditorView: View {
    enum Mode {
        case new
        case edit(RoutingRule)
    }

    var controller: TunnelController
    var mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var domains = ""
    @State private var domainSuffixes = ""
    @State private var domainKeywords = ""
    @State private var ipCIDRs = ""
    @State private var ports = ""
    @State private var selectedSets: Set<String> = []
    @State private var invert = false
    @State private var action: RoutingRule.Action = .route
    @State private var outboundID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Action", selection: $action) {
                        Text("Route").tag(RoutingRule.Action.route)
                        Text("Reject").tag(RoutingRule.Action.reject)
                        Text("Direct").tag(RoutingRule.Action.direct)
                    }
                    if action == .route {
                        Picker("Via", selection: $outboundID) {
                            Text("Active Selection").tag(UUID?.none)
                            ForEach(controller.configuration.groups) { group in
                                Text(group.name).tag(UUID?.some(group.id))
                            }
                            ForEach(controller.configuration.servers) { server in
                                Text(server.name).tag(UUID?.some(server.id))
                            }
                        }
                    }
                } footer: {
                    Text("Route sends matching traffic to the chosen target; Direct bypasses everything; Reject blocks it.")
                }

                Section {
                    field("Domains, e.g. example.com", text: $domains)
                    field("Suffixes, e.g. example.com", text: $domainSuffixes)
                    field("Keywords", text: $domainKeywords)
                    field("Networks, e.g. 10.0.0.0/8", text: $ipCIDRs)
                    field("Ports, e.g. 80, 443", text: $ports)
                    if !controller.configuration.ruleSets.isEmpty {
                        ForEach(controller.configuration.ruleSets) { set in
                            Button {
                                if selectedSets.contains(set.id.uuidString) {
                                    selectedSets.remove(set.id.uuidString)
                                } else {
                                    selectedSets.insert(set.id.uuidString)
                                }
                            } label: {
                                HStack {
                                    Text(set.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedSets.contains(set.id.uuidString) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                    Toggle("Invert Match", isOn: $invert)
                } header: {
                    Text("Match")
                } footer: {
                    Text("Values within one field match any; the fields combine. Every listed criterion is a comma-separated list.")
                }
            }
            .navigationTitle(isNew ? "New Rule" : "Edit Rule")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save", action: save)
                        .disabled(!draft.matchesSomething)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private var draft: RoutingRule {
        RoutingRule(domains: list(domains), domainSuffixes: list(domainSuffixes),
                    domainKeywords: list(domainKeywords), ipCIDRs: list(ipCIDRs),
                    ports: list(ports).compactMap(Int.init), ruleSetTags: Array(selectedSets),
                    invert: invert, action: action, outboundID: action == .route ? outboundID : nil)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
#if os(iOS)
            .textInputAutocapitalization(.never)
#endif
    }

    private func list(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func joined(_ values: [String]) -> String {
        values.joined(separator: ", ")
    }

    private func load() {
        guard case .edit(let rule) = mode else { return }
        domains = joined(rule.domains)
        domainSuffixes = joined(rule.domainSuffixes)
        domainKeywords = joined(rule.domainKeywords)
        ipCIDRs = joined(rule.ipCIDRs)
        ports = rule.ports.map(String.init).joined(separator: ", ")
        selectedSets = Set(rule.ruleSetTags)
        invert = rule.invert
        action = rule.action
        outboundID = rule.outboundID
    }

    private func save() {
        switch mode {
        case .new:
            controller.updateRules(controller.configuration.rules + [draft])
        case .edit(let rule):
            var updated = draft
            updated.id = rule.id
            var rules = controller.configuration.rules
            rules[rules.firstIndex { $0.id == rule.id }!] = updated
            controller.updateRules(rules)
        }
        dismiss()
    }
}

/// Creates or edits a remote rule-set reference.
struct RuleSetEditorView: View {
    enum Mode {
        case new
        case edit(RemoteRuleSet)
    }

    var mode: Mode
    var onSave: (RemoteRuleSet) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var updateInterval: TimeInterval = 86400

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("https://example.com/list.json", text: $url)
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
#endif
                    Picker("Refresh Every", selection: $updateInterval) {
                        Text("Hour").tag(TimeInterval(3600))
                        Text("6 hours").tag(TimeInterval(21600))
                        Text("12 hours").tag(TimeInterval(43200))
                        Text("Day").tag(TimeInterval(86400))
                        Text("3 days").tag(TimeInterval(259200))
                    }
                } footer: {
                    Text("The engine downloads the list itself and keeps it fresh in the background.")
                }
            }
            .navigationTitle(isNew ? "New Rule Set" : "Edit Rule Set")
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
                                  || url.trimmingCharacters(in: .whitespaces).isEmpty)
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
        guard case .edit(let set) = mode else { return }
        name = set.name
        url = set.url
        updateInterval = set.updateInterval
    }

    private func save() {
        var set = RemoteRuleSet(name: name.trimmingCharacters(in: .whitespaces),
                                url: url.trimmingCharacters(in: .whitespaces),
                                updateInterval: updateInterval)
        // Keep the original id so rules referencing the set stay intact.
        if case .edit(let original) = mode {
            set.id = original.id
        }
        onSave(set)
        dismiss()
    }
}
