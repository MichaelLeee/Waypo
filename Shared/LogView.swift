import SwiftUI

/// Shows the engine log lines captured by the tunnel provider and offers
/// them for export via the share sheet.
struct LogView: View {
    var controller: TunnelController

    @State private var logs = ""
    @State private var fetchFailed = false
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Engine Logs")
                .inlineTitleOnIOS()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            Task { await load() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                        ShareLink(item: logs, preview: SharePreview("Engine Logs", image: "doc.text"))
                            .disabled(logs.isEmpty)
                    }
                }
                .task { await load() }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
#endif
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && logs.isEmpty {
            ProgressView("Loading logs…")
        } else if fetchFailed {
            WaypoEmptyState(
                "Logs Unavailable",
                systemImage: "doc.text.magnifyingglass",
                message: "The engine is not running, so there is nothing to show."
            )
        } else if logs.isEmpty {
            WaypoEmptyState(
                "No Logs",
                systemImage: "doc.text",
                message: "Start the tunnel to capture engine output."
            )
        } else {
            ScrollView {
                Text(logs)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let fetched = await controller.fetchEngineLogs() {
            logs = fetched
            fetchFailed = false
        } else {
            fetchFailed = true
        }
    }
}
