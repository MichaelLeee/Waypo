import SwiftUI

/// Creates or edits one script.
///
/// The source field is the app's first `TextEditor`: monospaced, so indentation
/// lines up, and with autocorrection and autocapitalisation off, because both
/// would rewrite code as it is typed.
struct ScriptEditorView: View {
    enum Mode {
        case new
        case edit(Script)
    }

    var service: ScriptService
    var mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: ScriptKind = .manual
    @State private var source = ""
    @State private var argument = ""
    @State private var scheduleText = "every 30m"
    @State private var event: ScriptEvent = .tunnelConnected
    @State private var isEnabled = true
    @State private var isImported = false

    var body: some View {
        NavigationStack {
            Form {
                details
                if kind == .cron {
                    scheduleSection
                }
                if kind == .event {
                    eventSection
                }
                argumentSection
                sourceSection
                capabilitiesSection
            }
            .navigationTitle(isNew ? "New Script" : "Edit Script")
            .inlineTitleOnIOS()
            .editorToolbar(isSaveDisabled: !canSave) { save() }
        }
        .onAppear(perform: load)
    }

    private var details: some View {
        Section {
            TextField("Name", text: $name)
            Picker("Runs", selection: $kind) {
                ForEach(ScriptKind.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            Toggle("Enabled", isOn: $isEnabled)
                .disabled(isImported)
        } footer: {
            if isImported {
                Text("This script came from an imported configuration, so it cannot be switched on.")
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            TextField("every 5m, or a five-field expression", text: $scheduleText)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .modifier(NoAutocapitalization())
            if let scheduleError {
                ErrorText(scheduleError, alignment: .leading)
            } else if let next = parsedSchedule?.nextFireDate(after: Date()) {
                Text("Next run \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(Palette.neutral)
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("Use every 30s, every 5m, or every 2h, or a five-field expression like 0 9 * * 1-5. The shortest interval is 10 seconds.")
        }
    }

    private var eventSection: some View {
        Section("Event") {
            Picker("Fires", selection: $event) {
                ForEach(ScriptEvent.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
        }
    }

    private var argumentSection: some View {
        Section {
            TextField("Argument", text: $argument)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .modifier(NoAutocapitalization())
        } header: {
            Text("Argument")
        } footer: {
            Text("Handed to the script as $argument.")
        }
    }

    private var sourceSection: some View {
        Section {
            TextEditor(text: $source)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .modifier(NoAutocapitalization())
                .frame(minHeight: 200)
        } header: {
            Text("Source")
        } footer: {
            Text("Each run starts from a fresh context. Only $persistentStore carries values from one run to the next.")
        }
    }

    private var capabilitiesSection: some View {
        Section {
            Label("$waypo reads the profile, status, and server list", systemImage: "eye")
            Label("$waypo.selectServer(id) switches the active server", systemImage: "arrow.left.arrow.right")
            Label("$httpClient makes http and https requests", systemImage: "network")
            Label("$notify posts a notification", systemImage: "bell")
            Label("$persistentStore keeps values between runs", systemImage: "internaldrive")
        } header: {
            Text("What a script can do")
        } footer: {
            Text("A script runs code and can make network requests. Only add one you have read.")
        }
    }

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private var parsedSchedule: ScriptSchedule? {
        try? ScriptSchedule.parse(scheduleText)
    }

    /// Only cron needs a valid schedule to save; a manual or event script has
    /// nothing to parse.
    private var scheduleError: String? {
        guard kind == .cron else { return nil }
        do {
            _ = try ScriptSchedule.parse(scheduleText)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind == .cron {
            return parsedSchedule != nil
        }
        return true
    }

    private func load() {
        guard case .edit(let script) = mode else { return }
        name = script.name
        kind = script.kind
        source = script.source
        argument = script.argument ?? ""
        if let schedule = script.schedule {
            scheduleText = Self.text(for: schedule)
        }
        if let scriptEvent = script.event {
            event = scriptEvent
        }
        isEnabled = script.isEnabled
        isImported = script.origin == .imported
    }

    private static func text(for schedule: ScriptSchedule) -> String {
        switch schedule {
        case .interval(let seconds): "every \(seconds)s"
        case .cron(let expression): expression.text
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let schedule = kind == .cron ? parsedSchedule : nil
        let scriptEvent = kind == .event ? event : nil
        let argument = argument.isEmpty ? nil : argument

        switch mode {
        case .new:
            service.save(Script(name: trimmedName, kind: kind, source: source, argument: argument,
                                schedule: schedule, event: scriptEvent,
                                isEnabled: isEnabled && !isImported))
        case .edit(let script):
            var updated = script
            updated.name = trimmedName
            updated.kind = kind
            updated.source = source
            updated.argument = argument
            updated.schedule = schedule
            updated.event = scriptEvent
            // An imported script stays off whatever the toggle says, matching
            // the store's own rule rather than contradicting it.
            updated.isEnabled = isImported ? false : isEnabled
            service.save(updated)
        }
        dismiss()
    }
}

/// Autocapitalisation is a UIKit-only modifier, so it is applied where the
/// platform has it and skipped where it does not.
private struct NoAutocapitalization: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        content.textInputAutocapitalization(.never)
#else
        content
#endif
    }
}
