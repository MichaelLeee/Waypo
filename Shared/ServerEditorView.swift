import SwiftUI

struct ServerEditorView: View {
    enum Mode {
        case new
        case edit(TunnelServer)

        var title: String {
            switch self {
            case .new: "New Server"
            case .edit: "Edit Server"
            }
        }
    }

    var controller: TunnelController
    var mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var draft = TunnelServer(name: "", host: "", port: 443)

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    TextField("Name", text: $draft.name)
                    TextField("Host", text: $draft.host)

                        .autocorrectionDisabled()
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    Picker("Transport", selection: $draft.transport) {
                        Text("Direct").tag("direct")
                        Text("Trojan").tag("trojan")
                        Text("VLESS").tag("vless")
                        Text("Shadowsocks").tag("shadowsocks")
                        Text("Hysteria2").tag("hysteria2")
                    }
                    if draft.transport == "shadowsocks" {
                        TextField("Cipher", text: optionalString($draft.cipher))
                            .autocorrectionDisabled()

                    }
                    if draft.transport != "direct" {
                        TextField(credentialsTitle, text: optionalString($draft.credentials))
                            .autocorrectionDisabled()

                    }
                    if draft.transport == "hysteria2" {
                        Picker("Obfuscation", selection: obfsBinding) {
                            Text("None").tag("")
                            Text("Salamander").tag("salamander")
                        }
                        if !obfsBinding.wrappedValue.isEmpty {
                            TextField("Obfuscation Password", text: optionalString($draft.obfsPassword))
                                .autocorrectionDisabled()
                        }
                    }
                    if draft.transport == "trojan" || draft.transport == "vless" {
                        Picker("Network", selection: networkBinding) {
                            Text("TCP").tag("tcp")
                            Text("WebSocket").tag("ws")
                            Text("gRPC").tag("grpc")
                        }
                        if networkBinding.wrappedValue == "ws" {
                            TextField("Path", text: optionalString($draft.wsPath))
                                .autocorrectionDisabled()
                            TextField("Host Header", text: optionalString($draft.wsHost))
                                .autocorrectionDisabled()
                        }
                        if networkBinding.wrappedValue == "grpc" {
                            TextField("Service Name", text: optionalString($draft.serviceName))
                                .autocorrectionDisabled()
                        }
                        if draft.transport == "vless" {
                            TextField("Flow", text: optionalString($draft.flow))
                                .autocorrectionDisabled()
                        }
                    }
                }

                Section("TLS") {
                    Toggle("Use TLS", isOn: $draft.useTLS)
                        .disabled(draft.transport == "hysteria2")
                    if draft.useTLS || draft.transport == "hysteria2" {
                        TextField("Server Name", text: optionalString($draft.serverName))
                            .autocorrectionDisabled()
                        Toggle("Allow Insecure", isOn: $draft.allowInsecure)
                        TextField("Reality Public Key", text: optionalString($draft.realityPublicKey))
                            .autocorrectionDisabled()
                        if !(draft.realityPublicKey ?? "").isEmpty {
                            TextField("Reality Short ID", text: optionalString($draft.realityShortID))
                                .autocorrectionDisabled()
                        }
                    }
                }
            }
            .onChange(of: draft.transport) { _, newValue in
                // This transport cannot exist without TLS.
                if newValue == "hysteria2" {
                    draft.useTLS = true
                }
            }
            .navigationTitle(mode.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
        .onAppear {
            if case let .edit(server) = mode {
                draft = server
            }
        }
    }

    private var isValid: Bool {
        !draft.name.isEmpty && !draft.host.isEmpty && draft.port > 0 && draft.port < 65536
    }

    private func save() {
        switch mode {
        case .new:
            controller.addServer(draft)
        case .edit:
            controller.updateServer(draft)
        }
        dismiss()
    }

    private func optionalString(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private var networkBinding: Binding<String> {
        Binding(
            get: { draft.network ?? "tcp" },
            set: { draft.network = $0 == "tcp" ? nil : $0 }
        )
    }

    private var obfsBinding: Binding<String> {
        Binding(
            get: { draft.obfs ?? "" },
            set: { draft.obfs = $0.isEmpty ? nil : $0 }
        )
    }

    private var credentialsTitle: String {
        draft.transport == "trojan" || draft.transport == "hysteria2" ? "Password" : "Credentials"
    }
}
