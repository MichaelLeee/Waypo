import SwiftUI

/// Edits the resolver list, static hosts answers, and fake-IP settings.
struct DNSSettingsView: View {
    var controller: TunnelController

    @Environment(\.dismiss) private var dismiss
    @State private var resolvers: [DNSResolver] = []
    @State private var hosts: [DNSHostMapping] = []
    @State private var fakeIPEnabled = false
    @State private var fakeIPExclusions = ""
    @State private var editingResolver: DNSResolver?
    @State private var editingHost: DNSHostMapping?
    @State private var showingNewResolver = false
    @State private var showingNewHost = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(resolvers) { resolver in
                        Button {
                            editingResolver = resolver
                        } label: {
                            HStack {
                                Text(kindLabel(resolver.kind))
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 44, alignment: .leading)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(resolver.server)
                                        .foregroundStyle(.primary)
                                    if let detail = resolverDetail(resolver) {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .deleteDisabled(resolvers.count < 2)
                    }
                    .onDelete { offsets in
                        guard resolvers.count > offsets.count else { return }
                        resolvers.remove(atOffsets: offsets)
                        save()
                    }
                } header: {
                    Text("Resolvers")
                } footer: {
                    Text("Queries are tried in order. Encrypted kinds keep the questions private on the path to the resolver.")
                }

                Section {
                    ForEach(hosts) { host in
                        Button {
                            editingHost = host
                        } label: {
                            HStack {
                                Text(host.domain)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(host.address)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        hosts.remove(atOffsets: offsets)
                        save()
                    }
                } header: {
                    Text("Hosts")
                } footer: {
                    Text("Domains answered statically, without querying a resolver.")
                }

                Section {
                    Toggle("Fake Addresses", isOn: $fakeIPEnabled)
                    if fakeIPEnabled {
                        TextField("Excluded suffixes, e.g. company.lan", text: $fakeIPExclusions)
                    }
                } footer: {
                    Text("Fake addresses let the engine start routing before a real lookup finishes. Excluded suffixes always get real answers.")
                }
            }
            .navigationTitle("DNS")
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
                            showingNewResolver = true
                        } label: {
                            Label("Add Resolver", systemImage: "globe")
                        }
                        Button {
                            showingNewHost = true
                        } label: {
                            Label("Add Host", systemImage: "doc.plaintext")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .onAppear(perform: load)
            .sheet(item: $editingResolver) { resolver in
                ResolverEditorView(mode: .edit(resolver), resolverCount: resolvers.count) { updated in
                    resolvers[resolvers.firstIndex { $0.id == resolver.id }!] = updated
                    save()
                }
            }
            .sheet(isPresented: $showingNewResolver) {
                ResolverEditorView(mode: .new, resolverCount: resolvers.count) { resolver in
                    resolvers.append(resolver)
                    save()
                }
            }
            .sheet(item: $editingHost) { host in
                HostEditorView(mode: .edit(host)) { updated in
                    hosts[hosts.firstIndex { $0.id == host.id }!] = updated
                    save()
                }
            }
            .sheet(isPresented: $showingNewHost) {
                HostEditorView(mode: .new) { host in
                    hosts.append(host)
                    save()
                }
            }
        }
    }

    private func load() {
        resolvers = controller.configuration.dnsResolvers
        hosts = controller.configuration.dnsHosts
        fakeIPEnabled = controller.configuration.fakeIPEnabled
        fakeIPExclusions = controller.configuration.fakeIPExclusions.joined(separator: ", ")
    }

    private func save() {
        let exclusions = fakeIPExclusions
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        controller.updateDNS(resolvers: resolvers, hosts: hosts,
                             fakeIPEnabled: fakeIPEnabled, fakeIPExclusions: exclusions)
    }

    private func kindLabel(_ kind: DNSResolver.Kind) -> String {
        switch kind {
        case .udp: "UDP"
        case .https: "DoH"
        case .tls: "DoT"
        case .quic: "DoQ"
        }
    }

    private func resolverDetail(_ resolver: DNSResolver) -> String? {
        var parts: [String] = []
        if let port = resolver.serverPort, port > 0 {
            parts.append(":\(port)")
        }
        if resolver.kind == .https, let path = resolver.path, !path.isEmpty {
            parts.append(path)
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}

private struct ResolverEditorView: View {
    enum Mode {
        case new
        case edit(DNSResolver)
    }

    var mode: Mode
    var resolverCount: Int
    var onSave: (DNSResolver) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DNSResolver.Kind = .udp
    @State private var server = ""
    @State private var port = ""
    @State private var path = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("UDP").tag(DNSResolver.Kind.udp)
                        Text("DoH (HTTPS)").tag(DNSResolver.Kind.https)
                        Text("DoT (TLS)").tag(DNSResolver.Kind.tls)
                        Text("DoQ (QUIC)").tag(DNSResolver.Kind.quic)
                    }
                    TextField(kind == .udp ? "IP address" : "Server name", text: $server)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    if kind == .https {
                        TextField("Path", text: $path, prompt: Text("/dns-query"))
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle(isNew ? "New Resolver" : "Edit Resolver")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save", action: save)
                        .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private func load() {
        guard case .edit(let resolver) = mode else { return }
        kind = resolver.kind
        server = resolver.server
        if let serverPort = resolver.serverPort {
            port = String(serverPort)
        }
        path = resolver.path ?? ""
    }

    private func save() {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        let portNumber = Int(port)
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .new:
            onSave(DNSResolver(kind: kind, server: trimmed,
                               serverPort: portNumber,
                               path: kind == .https && !trimmedPath.isEmpty ? trimmedPath : nil))
        case .edit(let resolver):
            var updated = resolver
            updated.kind = kind
            updated.server = trimmed
            updated.serverPort = portNumber
            updated.path = kind == .https && !trimmedPath.isEmpty ? trimmedPath : nil
            onSave(updated)
        }
        dismiss()
    }
}

private struct HostEditorView: View {
    enum Mode {
        case new
        case edit(DNSHostMapping)
    }

    var mode: Mode
    var onSave: (DNSHostMapping) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Domain", text: $domain)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()
                    TextField("Address", text: $address, prompt: Text("IP address"))
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(isNew ? "New Host" : "Edit Host")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save", action: save)
                        .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty
                                  || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private func load() {
        guard case .edit(let host) = mode else { return }
        domain = host.domain
        address = host.address
    }

    private func save() {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespaces)
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .new:
            onSave(DNSHostMapping(domain: trimmedDomain, address: trimmedAddress))
        case .edit(let host):
            var updated = host
            updated.domain = trimmedDomain
            updated.address = trimmedAddress
            onSave(updated)
        }
        dismiss()
    }
}
