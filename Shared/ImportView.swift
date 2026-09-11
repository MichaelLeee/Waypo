import SwiftUI
import UniformTypeIdentifiers

/// Sheet for bringing in servers from pasted share-link text or a text file.
struct ImportView: View {
    var controller: TunnelController

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var urlString = ""
    @State private var isFetching = false
    @State private var importError: String?
    @State private var showingFileImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("https://example.com/list.txt", text: $urlString)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
#if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
#endif
                        Button("Fetch") {
                            Task { await fetchURL() }
                        }
                        .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty || isFetching)
                        if isFetching {
                            ProgressView()
                        }
                    }
                } header: {
                    Text("Download from URL")
                }

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                } header: {
                    Text("Paste share links or a configuration file")
                } footer: {
                    Text("Supported: trojan, vless, ss, hysteria2, tuic, vmess links, or a community YAML configuration.")
                }

                if let importError {
                    Section {
                        ErrorText(importError, alignment: .leading)
                    }
                }
            }
            .navigationTitle("Import")
            .inlineTitleOnIOS()
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
            allowedContentTypes: [.text, .json, .yaml]
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

    private func fetchURL() async {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else {
            importError = "That is not a valid URL."
            return
        }
        isFetching = true
        defer { isFetching = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                importError = "The server returned an error response."
                return
            }
            guard let fetched = String(data: data, encoding: .utf8) else {
                importError = "The response is not UTF-8 text."
                return
            }
            text = fetched
            importError = nil
        } catch {
            importError = error.localizedDescription
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
