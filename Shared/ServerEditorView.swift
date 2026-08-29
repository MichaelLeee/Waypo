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
                    }
                    if draft.transport == "shadowsocks" {
                        TextField("Cipher", text: optionalString($draft.cipher))
                            .autocorrectionDisabled()

                    }
                    if draft.transport != "direct" {
                        TextField("Credentials", text: optionalString($draft.credentials))
                            .autocorrectionDisabled()

                    }
                }

                Section("TLS") {
                    Toggle("Use TLS", isOn: $draft.useTLS)
                    if draft.useTLS {
                        TextField("Server Name", text: optionalString($draft.serverName))
                            .autocorrectionDisabled()

                    }
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
}
