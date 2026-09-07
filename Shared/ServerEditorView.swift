import CryptoKit
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
                        Text("TUIC").tag("tuic")
                        Text("VMess").tag("vmess")
                        Text("WireGuard").tag("wireguard")
                        Text("AnyTLS").tag("anytls")
                        Text("Shadow-TLS").tag("shadowtls")
                    }
                    if draft.transport == "shadowsocks" || draft.transport == "shadowtls" {
                        TextField("Cipher", text: optionalString($draft.cipher))
                            .autocorrectionDisabled()

                    }
                    if draft.transport == "vmess" {
                        TextField("Encryption", text: optionalString($draft.cipher))
                            .autocorrectionDisabled()
                        TextField("Alter ID", value: optionalInt($draft.alterId), format: .number.grouping(.never))
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
                    if draft.transport == "tuic" {
                        TextField("UUID", text: optionalString($draft.uuid))
                            .autocorrectionDisabled()
                        Picker("Congestion Control", selection: congestionBinding) {
                            Text("BBR").tag("bbr")
                            Text("Cubic").tag("cubic")
                        }
                    }
                    if draft.transport == "wireguard" {
                        HStack {
                            TextField("Private Key", text: optionalString($draft.wgPrivateKey))
                                .autocorrectionDisabled()
                            Button("Generate", action: generateKeyPair)
                        }
                        TextField("Peer Public Key", text: optionalString($draft.wgPeerPublicKey))
                            .autocorrectionDisabled()
                        TextField("Preshared Key", text: optionalString($draft.wgPresharedKey))
                            .autocorrectionDisabled()
                        TextField("Addresses", text: optionalString($draft.wgAddresses), prompt: Text("10.0.0.2/32, fd00::2/128"))
                            .autocorrectionDisabled()
                        TextField("Reserved", text: optionalString($draft.wgReserved))
                            .autocorrectionDisabled()
                    }
                    if draft.transport == "shadowtls" {
                        TextField("Shadow-TLS Password", text: optionalString($draft.shadowTLSPassword))
                            .autocorrectionDisabled()
                        Picker("Shadow-TLS Version", selection: shadowTLSVersionBinding) {
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("3").tag(3)
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
                        .disabled(draft.transport == "hysteria2" || draft.transport == "tuic"
                                  || draft.transport == "anytls" || draft.transport == "shadowtls")
                    if draft.useTLS || draft.transport == "hysteria2" || draft.transport == "tuic"
                        || draft.transport == "anytls" || draft.transport == "shadowtls" {
                        TextField("Server Name", text: optionalString($draft.serverName))
                            .autocorrectionDisabled()
                        if draft.transport != "shadowtls" {
                            TextField("ALPN", text: optionalString($draft.alpn))
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
            }
            .onChange(of: draft.transport) { _, newValue in
                // These transports cannot exist without TLS.
                if newValue == "hysteria2" || newValue == "tuic" || newValue == "anytls" {
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
        var valid = !draft.name.isEmpty && !draft.host.isEmpty && draft.port > 0 && draft.port < 65536
        if draft.transport == "wireguard" {
            valid = valid && !(draft.wgPrivateKey ?? "").isEmpty
                && !(draft.wgPeerPublicKey ?? "").isEmpty
                && !(draft.wgAddresses ?? "").isEmpty
        }
        return valid
    }

    private func generateKeyPair() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        draft.wgPrivateKey = key.rawRepresentation.base64EncodedString()
        draft.wgPeerPublicKey = key.publicKey.rawRepresentation.base64EncodedString()
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

    private func optionalInt(_ binding: Binding<Int?>) -> Binding<Int> {
        Binding(
            get: { binding.wrappedValue ?? 0 },
            set: { binding.wrappedValue = $0 == 0 ? nil : $0 }
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

    private var congestionBinding: Binding<String> {
        Binding(
            get: { draft.congestionControl ?? "bbr" },
            set: { draft.congestionControl = $0 }
        )
    }

    private var credentialsTitle: String {
        switch draft.transport {
        case "trojan", "hysteria2", "tuic", "anytls": "Password"
        case "shadowtls": "Inner Password"
        default: "Credentials"
        }
    }

    private var shadowTLSVersionBinding: Binding<Int> {
        Binding(
            get: { draft.shadowTLSVersion ?? 3 },
            set: { draft.shadowTLSVersion = $0 == 3 ? nil : $0 }
        )
    }
}
