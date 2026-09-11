import SwiftUI

/// Lists the profile's scripts, runs them by hand, and shows recent runs.
///
/// Scripts run while the app is open: nothing here is reached from the packet
/// tunnel provider, so a schedule does not fire while the app is closed. The
/// footer says so rather than leaving it to be discovered.
struct ScriptListView: View {
    var service: ScriptService

    @Environment(\.dismiss) private var dismiss
    @State private var editingScript: Script?
    @State private var showingNewScript = false
    @State private var viewingRecord: ScriptRunRecord?

    var body: some View {
        NavigationStack {
            Group {
                if service.scripts.isEmpty {
                    WaypoEmptyState(
                        "No Scripts",
                        systemImage: "curlybraces",
                        message: "Add a script to run it by hand, on a schedule, or when the connection changes."
                    )
                } else {
                    scriptsList
                }
            }
            .navigationTitle("Scripts")
            .inlineTitleOnIOS()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewScript = true
                    } label: {
                        Label("Add Script", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editingScript) { script in
                ScriptEditorView(service: service, mode: .edit(script))
            }
            .sheet(isPresented: $showingNewScript) {
                ScriptEditorView(service: service, mode: .new)
            }
            .sheet(item: $viewingRecord) { record in
                ScriptLogView(record: record)
            }
        }
    }

    private var scriptsList: some View {
        List {
            if service.isPaused {
                Section {
                    ErrorText(ScriptRuntime.pausedMessage, alignment: .leading)
                }
            }
            if let error = service.lastError {
                Section {
                    ErrorText(error, alignment: .leading)
                }
            }

            Section {
                ForEach(service.scripts) { script in
                    row(script)
                }
                .onDelete { offsets in
                    let deletable = service.scripts
                    for offset in offsets where offset < deletable.count {
                        service.delete(deletable[offset].id)
                    }
                }
            } header: {
                Text("Scripts")
            } footer: {
                Text("Scripts run while the app is open. A schedule or event does not fire while it is closed.")
            }

            if !service.history.isEmpty {
                Section("Recent Runs") {
                    ForEach(Array(service.history.prefix(20))) { record in
                        Button {
                            viewingRecord = record
                        } label: {
                            RunRow(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ script: Script) -> some View {
        Button {
            editingScript = script
        } label: {
            ScriptRow(script: script, isRunning: service.runningScriptIDs.contains(script.id))
        }
        .buttonStyle(.plain)
#if os(macOS)
        .contextMenu { rowMenu(script) }
#else
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                service.delete(script.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                service.runNow(script.id)
            } label: {
                Label("Run Now", systemImage: "play")
            }
            .tint(Palette.accent)
        }
        .contextMenu { rowMenu(script) }
#endif
    }

    @ViewBuilder
    private func rowMenu(_ script: Script) -> some View {
        Button {
            service.runNow(script.id)
        } label: {
            Label("Run Now", systemImage: "play")
        }
        Button {
            editingScript = script
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            service.delete(script.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct ScriptRow: View {
    var script: Script
    var isRunning: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(hasNoSchedule ? Palette.negative : Palette.neutral)
                if let next = nextRun {
                    Text("Next run \(next.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Palette.neutral)
                }
            }
            Spacer()
            if isRunning {
                ProgressView().controlSize(.small)
            } else if let outcome = script.lastOutcome {
                StatusPill(outcome.label, systemImage: outcome.symbol, tone: outcome.tone)
            }
            if script.origin == .imported {
                StatusPill("Imported", tone: .neutral)
            } else if !script.isEnabled {
                StatusPill("Off", tone: .neutral)
            }
        }
    }

    private var subtitle: String {
        switch script.kind {
        case .manual:
            "Runs only when you ask"
        case .cron:
            script.schedule.map(ScriptScheduler.nextFireDescription) ?? "No schedule set"
        case .event:
            script.event?.label ?? "No event chosen"
        }
    }

    private var hasNoSchedule: Bool {
        script.kind == .cron && script.schedule == nil
    }

    /// Only shown when the next fire is still ahead: an overdue script is about
    /// to run, and naming a time in the past would read as a fault.
    private var nextRun: Date? {
        guard script.isEnabled, script.kind == .cron, let schedule = script.schedule else {
            return nil
        }
        let anchor = script.lastScheduledFireAt ?? script.createdAt
        guard let next = schedule.nextFireDate(after: anchor), next > Date() else { return nil }
        return next
    }
}

private struct RunRow: View {
    var record: ScriptRunRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.scriptName)
                Text("\(record.trigger.label) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(Palette.neutral)
            }
            Spacer()
            StatusPill(record.outcome.label, systemImage: record.outcome.symbol, tone: record.outcome.tone)
        }
    }
}

extension ScriptKind {
    var label: String {
        switch self {
        case .manual: "Manual"
        case .cron: "Scheduled"
        case .event: "Event"
        }
    }
}

extension ScriptEvent {
    var label: String {
        switch self {
        case .tunnelConnected: "When the connection comes up"
        case .tunnelDisconnected: "When the connection goes down"
        case .appLaunched: "When the app launches"
        case .appForeground: "When the app returns to the foreground"
        }
    }
}

extension ScriptRunRecord.Trigger {
    var label: String {
        switch self {
        case .manual: "Run by hand"
        case .schedule: "Scheduled"
        case .event: "Event"
        }
    }
}

extension ScriptOutcome {
    var label: String {
        switch self {
        case .success: "Succeeded"
        case .timeout: "Timed out"
        case .error: "Failed"
        case .skipped: "Stopped"
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .timeout: "clock"
        case .error: "exclamationmark.triangle.fill"
        case .skipped: "pause.circle.fill"
        }
    }

    var tone: PillTone {
        switch self {
        case .success: .positive
        case .timeout: .caution
        case .error: .negative
        case .skipped: .neutral
        }
    }
}
