import SwiftUI
import UniformTypeIdentifiers

/// Sheet for bringing in servers from pasted share-link text or a text file.
struct ImportView: View {
    var controller: TunnelController

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var importError: String?
    @State private var showingFileImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                } header: {
                    Text("Paste share links, one per line")
                } footer: {
                    Text("Supported: trojan, vless, ss.")
                }

                if let importError {
                    Section {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Import", action: importNow)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Open File…") { showingFileImporter = true }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.text, .json]
        ) { handleFile($0) }
    }

    private func importNow() {
        let count = controller.importServers(fromText: text)
        if count == 0 {
            importError = "No valid entries were found."
        } else {
            dismiss()
        }
    }

    private func handleFile(_ result: Result<URL, any Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                text = try String(contentsOf: url, encoding: .utf8)
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
