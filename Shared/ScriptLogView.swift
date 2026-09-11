import SwiftUI

/// One past run in full: what it did, how long it took, and anything it printed.
struct ScriptLogView: View {
    var record: ScriptRunRecord

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ScriptOutputView(record: record)
                    .padding()
            }
            .navigationTitle(record.scriptName)
            .inlineTitleOnIOS()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
#endif
    }
}

/// The body of a run record, shared by the log sheet and anywhere else a run is
/// shown on its own.
struct ScriptOutputView: View {
    var record: ScriptRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let output = record.output, !output.isEmpty {
                block("Result", text: output)
            }
            if !record.log.isEmpty {
                block("Log", text: record.log.joined(separator: "\n"))
            }
            if (record.output?.isEmpty ?? true) && record.log.isEmpty {
                Text("The script produced no output.")
                    .font(.footnote)
                    .foregroundStyle(Palette.neutral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusPill(record.outcome.label, systemImage: record.outcome.symbol, tone: record.outcome.tone)
            Text("\(record.trigger.label) · \(record.startedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.footnote)
                .foregroundStyle(Palette.neutral)
            Text(duration)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Palette.neutral)
        }
        .textSelection(.enabled)
    }

    /// Milliseconds below a second, so a fast run does not read as "0.00 s".
    private var duration: String {
        record.duration < 1
            ? String(format: "%.0f ms", record.duration * 1000)
            : String(format: "%.2f s", record.duration)
    }

    @ViewBuilder
    private func block(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
