import Foundation

/// One thing that happened to one part of an imported configuration.
///
/// `detail` is written once, here, as the sentence the user reads. Keeping it
/// a plain string rather than a closure is what lets the whole report cross an
/// `await` boundary and be encoded by a test.
struct ImportNotice: Hashable, Sendable, Identifiable {
    enum Severity: String, Sendable, CaseIterable {
        /// Something was interpreted differently than written.
        case info
        /// Something was approximated, or a setting was ignored.
        case warning
        /// Something in the document was left out entirely.
        case dropped

        /// Ordered by how much the user needs to know, so the worst notice in
        /// a report is a single `max`. Declaration order is not significance
        /// order, so this is explicit.
        var rank: Int {
            switch self {
            case .info: return 0
            case .warning: return 1
            case .dropped: return 2
            }
        }

        var displayName: String {
            switch self {
            case .info: return "Adjusted"
            case .warning: return "Approximated"
            case .dropped: return "Not imported"
            }
        }
    }

    /// Which part of the document the notice is about.
    enum Section: String, Sendable, CaseIterable {
        case servers
        case groups
        case rules
        case ruleProviders
        case dns

        var displayName: String {
            switch self {
            case .servers: return "Servers"
            case .groups: return "Groups"
            case .rules: return "Rules"
            case .ruleProviders: return "Rule sets"
            case .dns: return "DNS"
            }
        }
    }

    var id: UUID = UUID()
    var severity: Severity
    var section: Section
    var detail: String
}

/// What an import produced, and everything about the document that did not
/// survive it.
///
/// The counts are what reached the profile; the notices are what did not.
/// A report with counts and no notices means the document was understood
/// exactly as written.
struct ImportReport: Hashable, Sendable {
    var serversImported = 0
    var groupsImported = 0
    var rulesImported = 0
    var ruleProvidersImported = 0
    var dnsConfigured = false
    var notices: [ImportNotice] = []

    var droppedCount: Int { notices.filter { $0.severity == .dropped }.count }

    /// The most serious thing that happened, or nil when nothing did.
    var worstSeverity: ImportNotice.Severity? {
        notices.map(\.severity).max { $0.rank < $1.rank }
    }

    var importedSomething: Bool {
        serversImported > 0 || groupsImported > 0 || rulesImported > 0
            || ruleProvidersImported > 0 || dnsConfigured
    }

    /// One line for the list of what was imported, or why nothing was.
    var summaryLine: String {
        var parts: [String] = []
        if serversImported > 0 { parts.append(count(serversImported, "server")) }
        if groupsImported > 0 { parts.append(count(groupsImported, "group")) }
        if rulesImported > 0 { parts.append(count(rulesImported, "rule")) }
        if ruleProvidersImported > 0 { parts.append(count(ruleProvidersImported, "rule set")) }
        if dnsConfigured { parts.append("DNS settings") }
        guard !parts.isEmpty else { return "Nothing was imported." }
        return parts.joined(separator: ", ") + "."
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

/// The result of handing a document to the app.
///
/// Importing is not all-or-nothing: a document can be a full configuration,
/// or a plain list of links, and the two land in different places. The cases
/// are distinct so a caller cannot mistake "appended three servers" for
/// "created a profile".
enum ImportOutcome: Sendable, Equatable {
    /// Links were appended to the profile that is already active.
    case servers(added: Int)
    /// A whole configuration became its own profile.
    case configuration(ImportReport)
    case failure(String)
}
