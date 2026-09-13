import Foundation

/// A whole configuration read out of a community-format document, together
/// with everything about that document which did not survive the reading.
struct ConfigurationImportResult: Sendable, Equatable {
    var configuration: TunnelConfiguration
    var report: ImportReport
    /// Best-effort name for the document, when it states one. The caller
    /// decides what to fall back to.
    var name: String?
}

/// Maps a community-format document onto the app's own model.
///
/// The mapping is deliberately partial: the engine supports a subset of what
/// the format allows, and every part that does not map is recorded in the
/// report rather than quietly reinterpreted. A document is never rejected for
/// containing something unsupported, and a rule that cannot be understood is
/// never turned into a rule that matches everything.
enum ConfigurationImport {
    /// The top-level keys that make a document a configuration.
    ///
    /// Detection is structural on purpose. Weaker keys like `port:` or `mode:`
    /// appear in ordinary notes, and the YAML reader returns a non-nil empty
    /// document for arbitrary text, so neither "contains a colon" nor
    /// "parsed without error" distinguishes a configuration from anything else
    /// the user might paste.
    static let recognizedKeys: Set<String> = [
        "proxies", "proxy-groups", "proxy-providers",
        "rules", "dns", "rule-providers",
    ]

    static func isConfigurationDocument(_ text: String) -> Bool {
        guard let document = SubscriptionYAML.parseDocument(text) else { return false }
        return !recognizedKeys.isDisjoint(with: document.keys)
    }

    static func parse(_ text: String) -> ConfigurationImportResult? {
        guard let document = SubscriptionYAML.parseDocument(text),
              !recognizedKeys.isDisjoint(with: document.keys)
        else { return nil }
        return parse(document: document)
    }

    static func parse(document: [String: Any]) -> ConfigurationImportResult {
        var serverNotices: [ImportNotice] = []
        let proxies = ServerImport.parseProxies(document["proxies"])
        serverNotices += proxies.skipped.map {
            ImportNotice(severity: .dropped, section: .servers, detail: $0.detail)
        }

        var serverIDByName: [String: UUID] = [:]
        for server in proxies.servers {
            if serverIDByName[server.name] == nil {
                serverIDByName[server.name] = server.id
            } else {
                serverNotices.append(ImportNotice(
                    severity: .warning, section: .servers,
                    detail: "“\(server.name)” appears more than once; references to that name use the first entry."))
            }
        }

        // Rule sets are read before the rules that refer to them, so a rule can
        // resolve a set name straight to the tag the engine is given.
        let (ruleSets, ruleSetTagByName, providerNotices) = parseRuleProviders(document["rule-providers"])

        let (groups, groupNotices) = parseGroups(
            document["proxy-groups"], serverIDByName: serverIDByName)

        var outboundIDByName = serverIDByName
        for group in groups where outboundIDByName[group.name] == nil {
            outboundIDByName[group.name] = group.id
        }

        let (rules, finalPolicy, ruleNotices) = parseRules(
            document["rules"], ruleSetTagByName: ruleSetTagByName, outboundIDByName: outboundIDByName)

        let (dns, dnsNotices) = parseDNS(document["dns"])

        var report = ImportReport()
        report.serversImported = proxies.servers.count
        report.groupsImported = groups.count
        report.rulesImported = rules.count
        report.ruleProvidersImported = ruleSets.count
        report.dnsConfigured = dns.configured
        report.notices = serverNotices + groupNotices + providerNotices + ruleNotices + dnsNotices

        let configuration = TunnelConfiguration(
            servers: proxies.servers,
            groups: groups,
            mtu: 1500,
            dnsResolvers: dns.resolvers.isEmpty ? nil : dns.resolvers,
            dnsHosts: dns.hosts,
            fakeIPEnabled: dns.fakeIPEnabled,
            fakeIPExclusions: dns.fakeIPExclusions,
            rules: rules,
            ruleSets: ruleSets,
            finalPolicy: finalPolicy
        )

        let name = stringValue(document["name"])?.trimmingCharacters(in: .whitespaces)
        return ConfigurationImportResult(
            configuration: configuration, report: report, name: (name?.isEmpty ?? true) ? nil : name)
    }

    // MARK: - Groups

    /// A group as written, before its members have been turned into ids.
    private struct PendingGroup {
        var id: UUID
        var name: String
        var kind: PolicyGroupKind
        var url: String
        var interval: TimeInterval
        var memberNames: [String]
    }

    private static func parseGroups(
        _ raw: Any?, serverIDByName: [String: UUID]
    ) -> ([PolicyGroup], [ImportNotice]) {
        guard let raw else { return ([], []) }
        guard let entries = raw as? [[String: Any]] else {
            return ([], [ImportNotice(severity: .dropped, section: .groups,
                                      detail: "Groups were not in a form this app reads and were left out.")])
        }

        var notices: [ImportNotice] = []
        var pending: [PendingGroup] = []
        var groupIDByName: [String: UUID] = [:]

        for entry in entries {
            guard let name = stringValue(entry["name"]), !name.isEmpty else {
                notices.append(ImportNotice(severity: .dropped, section: .groups,
                                            detail: "A group in the document has no name and was left out."))
                continue
            }
            guard groupIDByName[name] == nil else {
                notices.append(ImportNotice(
                    severity: .warning, section: .groups,
                    detail: "“\(name)” is defined more than once as a group; the first definition was kept."))
                continue
            }

            let kind: PolicyGroupKind
            switch stringValue(entry["type"])?.lowercased() ?? "select" {
            case "select":
                kind = .select
            case "url-test":
                kind = .urlTest
            case let other:
                // The engine has no fallback or load-balancing strategy, and a
                // manual selector over the same members is the closest thing
                // that still works rather than a silent loss of the group.
                kind = .select
                notices.append(ImportNotice(
                    severity: .warning, section: .groups,
                    detail: "Group “\(name)” uses “\(other)”, which is not supported; it imports as a manual selector."))
            }

            let defaults = PolicyGroup(name: name, kind: kind)
            let id = defaults.id
            groupIDByName[name] = id
            pending.append(PendingGroup(
                id: id,
                name: name,
                kind: kind,
                url: stringValue(entry["url"]) ?? defaults.url,
                interval: seconds(entry["interval"]) ?? defaults.interval,
                memberNames: stringList(entry["proxies"])
            ))
        }

        let resolved = resolveGroups(pending, serverIDByName: serverIDByName,
                                     groupIDByName: groupIDByName, notices: &notices)
        return (resolved, notices)
    }

    /// Turns member names into ids and then removes anything the engine could
    /// not be given: a group with no members, and a group that can reach
    /// itself. Members resolve in one namespace over servers and groups, so a
    /// group may contain another group.
    private static func resolveGroups(
        _ pending: [PendingGroup],
        serverIDByName: [String: UUID],
        groupIDByName: [String: UUID],
        notices: inout [ImportNotice]
    ) -> [PolicyGroup] {
        let serverIDs = Set(serverIDByName.values)
        var order: [UUID] = []
        var byID: [UUID: PendingGroup] = [:]
        var names: [UUID: String] = [:]
        var members: [UUID: [UUID]] = [:]

        for group in pending {
            order.append(group.id)
            byID[group.id] = group
            names[group.id] = group.name
            var resolved: [UUID] = []
            var seen = Set<String>()
            for name in group.memberNames where seen.insert(name).inserted {
                if let id = serverIDByName[name] ?? groupIDByName[name] {
                    if !resolved.contains(id) { resolved.append(id) }
                } else {
                    notices.append(ImportNotice(
                        severity: .dropped, section: .groups,
                        detail: "Group “\(group.name)” refers to “\(name)”, which the document does not define."))
                }
            }
            members[group.id] = resolved
        }

        var alive = Set(order)
        pruneUnusableGroups(order: order, names: names, members: &members,
                            alive: &alive, serverIDs: serverIDs, notices: &notices)
        breakCycles(order: order, names: names, members: &members, alive: alive, notices: &notices)
        // Breaking a cycle can leave a group with nothing left to route to.
        pruneUnusableGroups(order: order, names: names, members: &members,
                            alive: &alive, serverIDs: serverIDs, notices: &notices)

        return order.compactMap { id in
            guard alive.contains(id), let group = byID[id], let memberIDs = members[id],
                  !memberIDs.isEmpty
            else { return nil }
            return PolicyGroup(id: id, name: group.name, kind: group.kind, memberIDs: memberIDs,
                               url: group.url, interval: group.interval)
        }
    }

    /// Drops, repeatedly, any group that can no longer reach a server either
    /// directly or through a group that is still alive. Repeating is what
    /// handles a group whose only members are groups that were themselves
    /// dropped.
    private static func pruneUnusableGroups(
        order: [UUID], names: [UUID: String],
        members: inout [UUID: [UUID]], alive: inout Set<UUID>,
        serverIDs: Set<UUID>, notices: inout [ImportNotice]
    ) {
        var changed = true
        while changed {
            changed = false
            for id in order where alive.contains(id) {
                let usable = (members[id] ?? []).filter { serverIDs.contains($0) || alive.contains($0) }
                if usable.isEmpty {
                    alive.remove(id)
                    changed = true
                    notices.append(ImportNotice(
                        severity: .dropped, section: .groups,
                        detail: "Group “\(names[id] ?? "Unnamed group")” has no usable members and was left out."))
                }
                members[id] = usable
            }
        }
    }

    /// Removes references that close a loop. An imported configuration must
    /// never reach the engine as a graph that is not acyclic, and the format
    /// does not guarantee one.
    private static func breakCycles(
        order: [UUID], names: [UUID: String],
        members: inout [UUID: [UUID]], alive: Set<UUID>,
        notices: inout [ImportNotice]
    ) {
        let budget = members.values.reduce(0) { $0 + $1.count } + 1
        var removed = 0
        while removed < budget,
              let edge = cycleEdge(order: order, members: members, alive: alive) {
            removed += 1
            members[edge.group]?.removeAll { $0 == edge.member }
            notices.append(ImportNotice(
                severity: .dropped, section: .groups,
                detail: "Group “\(names[edge.group] ?? "Unnamed group")” leads back to itself through "
                    + "“\(names[edge.member] ?? "a group")”, so that reference was removed."))
        }
    }

    private static func cycleEdge(
        order: [UUID], members: [UUID: [UUID]], alive: Set<UUID>
    ) -> (group: UUID, member: UUID)? {
        for group in order where alive.contains(group) {
            for member in members[group] ?? [] where alive.contains(member) {
                if member == group || reaches(member, group, members: members, alive: alive) {
                    return (group, member)
                }
            }
        }
        return nil
    }

    private static func reaches(
        _ start: UUID, _ target: UUID, members: [UUID: [UUID]], alive: Set<UUID>
    ) -> Bool {
        var stack = [start]
        var seen: Set<UUID> = []
        while let current = stack.popLast() {
            guard seen.insert(current).inserted else { continue }
            if current == target { return true }
            for next in members[current] ?? [] where alive.contains(next) {
                stack.append(next)
            }
        }
        return false
    }

    // MARK: - Rule sets

    private static func parseRuleProviders(
        _ raw: Any?
    ) -> ([RemoteRuleSet], [String: String], [ImportNotice]) {
        guard let raw else { return ([], [:], []) }
        guard let providers = raw as? [String: Any] else {
            return ([], [:], [ImportNotice(severity: .dropped, section: .ruleProviders,
                                           detail: "Rule sets were not in a form this app reads and were left out.")])
        }

        var notices: [ImportNotice] = []
        var sets: [RemoteRuleSet] = []
        var tagByName: [String: String] = [:]
        // Sorted so the report reads the same way for the same document.
        for name in providers.keys.sorted() {
            guard let entry = providers[name] as? [String: Any] else {
                notices.append(ImportNotice(severity: .dropped, section: .ruleProviders,
                                            detail: "Rule set “\(name)” was not in a form this app reads and was left out."))
                continue
            }
            guard let url = stringValue(entry["url"]) else {
                // An inline or local-file set has nothing the engine can fetch.
                notices.append(ImportNotice(
                    severity: .dropped, section: .ruleProviders,
                    detail: "Rule set “\(name)” is not a remote list and was left out."))
                continue
            }
            let kind = stringValue(entry["type"])?.lowercased()
            guard kind == nil || kind == "http" else {
                notices.append(ImportNotice(
                    severity: .dropped, section: .ruleProviders,
                    detail: "Rule set “\(name)” is not a remote list and was left out."))
                continue
            }
            var set = RemoteRuleSet(name: name, url: url)
            if let interval = seconds(entry["interval"]) { set.updateInterval = interval }
            sets.append(set)
            tagByName[name] = set.id.uuidString
        }
        return (sets, tagByName, notices)
    }

    // MARK: - Rules

    private enum Target {
        case direct
        case reject
        case outbound(UUID)
        case unresolved(String)
    }

    private static func parseRules(
        _ raw: Any?, ruleSetTagByName: [String: String], outboundIDByName: [String: UUID]
    ) -> ([RoutingRule], FinalPolicy, [ImportNotice]) {
        guard let raw else { return ([], .active, []) }
        guard let entries = raw as? [Any] else {
            return ([], .active, [ImportNotice(severity: .dropped, section: .rules,
                                               detail: "Rules were not in a form this app reads and were left out.")])
        }

        var notices: [ImportNotice] = []
        var rules: [RoutingRule] = []
        var finalPolicy = FinalPolicy.active

        for (position, entry) in entries.enumerated() {
            guard let text = entry as? String else {
                notices.append(ImportNotice(severity: .dropped, section: .rules,
                                            detail: "Rule \(position + 1) was not text and was left out."))
                continue
            }
            // Modifiers after the target, such as "no-resolve", have no field
            // to map onto and are ignored.
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let rawType = parts.first, !rawType.isEmpty else {
                notices.append(ImportNotice(severity: .dropped, section: .rules,
                                            detail: "The rule “\(text)” has no type and was left out."))
                continue
            }
            let type = rawType.uppercased()

            if type == "MATCH" {
                let target = self.target(parts.count > 1 ? parts[1] : "", byName: outboundIDByName)
                switch target {
                case .direct: finalPolicy = FinalPolicy(kind: .direct)
                case .reject: finalPolicy = FinalPolicy(kind: .reject)
                case .outbound(let id): finalPolicy = FinalPolicy(kind: .outbound, outboundID: id)
                case .unresolved(let name):
                    finalPolicy = .active
                    notices.append(ImportNotice(
                        severity: .warning, section: .rules,
                        detail: "The catch-all rule points at “\(name)”, which the document does not define; "
                            + "the active selection is used instead."))
                }
                continue
            }

            guard parts.count >= 3, !parts[1].isEmpty else {
                notices.append(ImportNotice(severity: .dropped, section: .rules,
                                            detail: "The rule “\(text)” is incomplete and was left out."))
                continue
            }
            let value = parts[1]

            var rule = RoutingRule()
            switch type {
            case "DOMAIN": rule.domains = [value]
            case "DOMAIN-SUFFIX": rule.domainSuffixes = [value]
            case "DOMAIN-KEYWORD": rule.domainKeywords = [value]
            case "IP-CIDR", "IP-CIDR6": rule.ipCIDRs = [value]
            case "DST-PORT":
                guard let port = Int(value) else {
                    notices.append(ImportNotice(
                        severity: .dropped, section: .rules,
                        detail: "The rule “\(text)” has a port this app cannot read and was left out."))
                    continue
                }
                rule.ports = [port]
            case "RULE-SET":
                guard let tag = ruleSetTagByName[value] else {
                    notices.append(ImportNotice(
                        severity: .dropped, section: .rules,
                        detail: "The rule “\(text)” refers to a rule set the document does not define and was left out."))
                    continue
                }
                rule.ruleSetTags = [tag]
            default:
                notices.append(ImportNotice(
                    severity: .dropped, section: .rules,
                    detail: "Rule type “\(type)” is not supported, so “\(text)” was left out."))
                continue
            }

            switch target(parts[2], byName: outboundIDByName) {
            case .direct:
                rule.action = .direct
            case .reject:
                rule.action = .reject
            case .outbound(let id):
                rule.action = .route
                rule.outboundID = id
            case .unresolved(let name):
                // Routing somewhere is closer to the document than not routing
                // at all, but the destination it asked for is not available.
                rule.action = .route
                notices.append(ImportNotice(
                    severity: .warning, section: .rules,
                    detail: "“\(text)” points at “\(name)”, which the document does not define; "
                        + "the active selection is used instead."))
            }
            rules.append(rule)
        }

        return (rules, finalPolicy, notices)
    }

    private static func target(_ raw: String, byName: [String: UUID]) -> Target {
        switch raw.uppercased() {
        case "DIRECT": return .direct
        case "REJECT", "REJECT-DROP": return .reject
        default:
            if let id = byName[raw] { return .outbound(id) }
            return .unresolved(raw)
        }
    }

    // MARK: - DNS

    private struct DNSParse {
        var resolvers: [DNSResolver] = []
        var hosts: [DNSHostMapping] = []
        var fakeIPEnabled = false
        var fakeIPExclusions: [String] = []
        var configured: Bool {
            !resolvers.isEmpty || !hosts.isEmpty || fakeIPEnabled
        }
    }

    private static func parseDNS(_ raw: Any?) -> (DNSParse, [ImportNotice]) {
        guard let raw else { return (DNSParse(), []) }
        guard let dns = raw as? [String: Any] else {
            return (DNSParse(), [ImportNotice(severity: .dropped, section: .dns,
                                              detail: "DNS settings were not in a form this app reads and were left out.")])
        }

        var parsed = DNSParse()
        var notices: [ImportNotice] = []
        for name in stringList(dns["nameserver"]) {
            if let resolver = resolver(from: name) {
                parsed.resolvers.append(resolver)
                continue
            }
            notices.append(ImportNotice(
                severity: .warning, section: .dns,
                detail: "DNS server “\(name)” was not in a form this app reads and was left out."))
        }

        if let rawHosts = dns["hosts"] as? [String: Any] {
            for domain in rawHosts.keys.sorted() {
                for address in stringList(rawHosts[domain]) {
                    parsed.hosts.append(DNSHostMapping(domain: domain, address: address))
                }
            }
        }

        if stringValue(dns["enhanced-mode"])?.lowercased() == "fake-ip" {
            parsed.fakeIPEnabled = true
        }
        parsed.fakeIPExclusions = stringList(dns["fake-ip-filter"])

        // These have no counterpart in the model: the app has one set of
        // resolvers with no fallback tier, and the fake address range is the
        // engine's own constant.
        for key in ["fallback", "nameserver-policy", "default-nameserver", "fake-ip-range"]
        where dns[key] != nil {
            notices.append(ImportNotice(severity: .warning, section: .dns,
                                        detail: "DNS option “\(key)” has no equivalent here and was left out."))
        }

        return (parsed, notices)
    }

    /// One resolver address as the format writes it: bare, or with the scheme
    /// of the encrypted transport in front.
    private static func resolver(from text: String) -> DNSResolver? {
        if text.lowercased().hasPrefix("https://") {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
            let path = url.path
            return DNSResolver(kind: .https, server: host, serverPort: url.port,
                               path: (path.isEmpty || path == "/") ? nil : path)
        }
        let schemes: [(prefix: String, kind: DNSResolver.Kind)] = [
            ("tls://", .tls), ("quic://", .quic),
        ]
        if let match = schemes.first(where: { text.lowercased().hasPrefix($0.prefix) }) {
            let (host, port) = hostAndPort(String(text.dropFirst(match.prefix.count)))
            guard !host.isEmpty else { return nil }
            return DNSResolver(kind: match.kind, server: host, serverPort: port)
        }
        // Any other scheme is a transport this app does not speak; leaving it
        // out is better than passing the scheme through as an address.
        guard !text.contains("://") else { return nil }
        let (host, port) = hostAndPort(text)
        guard !host.isEmpty else { return nil }
        return DNSResolver(kind: .udp, server: host, serverPort: port)
    }

    private static func hostAndPort(_ text: String) -> (String, Int?) {
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return (text, nil) }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = String(text[text.index(after: close)...])
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        guard let colon = text.lastIndex(of: ":") else { return (text, nil) }
        let host = String(text[..<colon])
        // More than one colon and no brackets is a bare IPv6 address, which
        // has no port to strip.
        guard !host.contains(":") else { return (text, nil) }
        return (host, Int(text[text.index(after: colon)...]))
    }

    // MARK: - Scalar helpers

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let single = stringValue(value) { return [single] }
        guard let list = value as? [Any] else { return [] }
        return list.compactMap(stringValue)
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return seconds > 0 ? seconds : nil
        }
        if let text = value as? String, let seconds = Double(text), seconds > 0 { return seconds }
        return nil
    }
}
