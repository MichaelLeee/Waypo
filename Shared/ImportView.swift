import SwiftUI
import UniformTypeIdentifiers

/// Sheet for bringing in servers from pasted share-link text, a text file, or a
/// remote source the resulting profile can keep itself current from.
struct ImportView: View {
    var controller: TunnelController

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var urlString = ""
    @State private var isFetching = false
    @State private var importError: String?
    @State private var report: ImportReport?
    @State private var fetched: SubscriptionFetchResult?
    @State private var showingFileImporter = false
    @State private var keepUpToDate = false
    @State private var interval = Subscription.defaultInterval

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                editorSection

                if let report {
                    ImportReportSection(report: report)
                }

                if let fetched, fetched.userInfo != nil {
                    Section("Account") {
                        SubscriptionSummary(userInfo: fetched.userInfo,
                                            lastUpdated: nil, lastError: nil)
                    }
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

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            TextField("https://example.com/list.txt", text: $urlString)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
#endif
            Toggle("Keep Up To Date", isOn: $keepUpToDate)
            if keepUpToDate {
                Picker("Check for Updates", selection: $interval) {
                    Text("Every 6 Hours").tag(TimeInterval(6 * 3_600))
                    Text("Every 12 Hours").tag(TimeInterval(12 * 3_600))
                    Text("Daily").tag(TimeInterval(86_400))
                    Text("Every 3 Days").tag(TimeInterval(3 * 86_400))
                    Text("Weekly").tag(TimeInterval(7 * 86_400))
                }
            }
            HStack {
                Button(keepUpToDate ? "Import" : "Fetch") {
                    Task { await fetchURL() }
                }
                .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty || isFetching)
                if isFetching {
                    ProgressView()
                }
            }
        } header: {
            Text("Download from URL")
        } footer: {
            if keepUpToDate {
                Text("This source is re-read while the app is open. A source that cannot be reached keeps the entries it already gave you.")
            }
        }
    }

    @ViewBuilder
    private var editorSection: some View {
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
    }

    private func importNow() {
        present(controller.importText(fromText: text))
    }

    /// With "Keep Up To Date" on, the fetched document goes straight into a
    /// profile that refreshes itself. Otherwise it fills the editor, so a
    /// source can be looked over before anything is created from it.
    private func fetchURL() async {
        importError = nil
        isFetching = true
        defer { isFetching = false }

        if keepUpToDate {
            let outcome = await controller.importSubscription(urlString: urlString,
                                                             interval: interval)
            present(outcome)
            return
        }
        do {
            let result = try await SubscriptionFetcher().fetch(urlString)
            fetched = result
            text = result.text
            report = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    /// One place that decides what an outcome means on screen. A configuration
    /// that arrived with something worth reading stays open so the notices can
    /// be read; one that arrived clean closes the sheet.
    private func present(_ outcome: ImportOutcome) {
        switch outcome {
        case .servers(let added):
            if added == 0 {
                importError = "No valid entries were found."
            } else {
                dismiss()
            }
        case .configuration(let imported):
            importError = nil
            report = imported
            if !imported.notices.contains(where: { $0.severity != .info }) { dismiss() }
        case .failure(let message):
            importError = message
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

/// What an import produced, and everything in the document that did not
/// survive it. A partial import is shown rather than hidden, because the whole
/// point of the report is to let the user judge what they got.
struct ImportReportSection: View {
    var report: ImportReport

    var body: some View {
        Section {
            Text(report.summaryLine)
            ForEach(ImportNotice.Severity.allCases, id: \.self) { severity in
                let notices = report.notices.filter { $0.severity == severity }
                if !notices.isEmpty {
                    DisclosureGroup {
                        ForEach(notices) { notice in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notice.section.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Palette.neutral)
                                Text(notice.detail)
                                    .font(.footnote)
                            }
                        }
                    } label: {
                        HStack {
                            Text(severity.displayName)
                            Spacer()
                            StatusPill("\(notices.count)", tone: Self.tone(for: severity))
                        }
                    }
                }
            }
        } header: {
            Text("Imported")
        }
    }

    private static func tone(for severity: ImportNotice.Severity) -> PillTone {
        switch severity {
        case .info: .accent
        case .warning: .caution
        case .dropped: .negative
        }
    }
}
