import Foundation
import Testing

@Suite
struct ConfigurationImportTests {
    // MARK: - Detection

    @Test
    func detectionIsKeyBased() {
        // Any one of the structural keys makes a document a configuration, so a
        // file that carries only groups, only rules, or only DNS still counts.
        #expect(ConfigurationImport.isConfigurationDocument("""
        proxies:
          - name: A
            type: trojan
        """))
        #expect(ConfigurationImport.isConfigurationDocument("proxy-groups:\n  - name: Pick\n    type: select"))
        #expect(ConfigurationImport.isConfigurationDocument("rules:\n  - MATCH,DIRECT"))
        #expect(ConfigurationImport.isConfigurationDocument("dns:\n  nameserver: 1.1.1.1"))
        #expect(ConfigurationImport.isConfigurationDocument(
            "rule-providers:\n  ads:\n    url: https://example.com/ads.yaml"))
        #expect(ConfigurationImport.isConfigurationDocument(
            "proxy-providers:\n  pool:\n    url: https://example.com/pool.yaml"))
    }

    @Test
    func textThatIsNotAConfigurationIsNotDetected() {
        // A share link, a base64 blob, and ordinary notes all fail the
        // structural test. Weak keys such as `port:` are deliberately not part
        // of it, because any pasted note can contain those.
        #expect(!ConfigurationImport.isConfigurationDocument("trojan://pass@example.com:443#Node"))
        #expect(!ConfigurationImport.isConfigurationDocument("dHJvamFuOi8vcGFzc0BleGFtcGxlLmNvbTo0NDM="))
        #expect(!ConfigurationImport.isConfigurationDocument("port: 8080\nmode: rule"))
        #expect(!ConfigurationImport.isConfigurationDocument("notes to self\nanother line: here"))
        #expect(ConfigurationImport.parse("trojan://pass@example.com:443#Node") == nil)
    }

    // MARK: - Servers

    @Test
    func aProxiesOnlyDocumentStillImports() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
          - name: Beta
            type: ss
            server: 203.0.113.11
            port: 8388
            cipher: aes-128-gcm
            password: p
        """))
        #expect(result.configuration.servers.count == 2)
        #expect(result.configuration.servers.map(\.name) == ["Alpha", "Beta"])
        #expect(result.configuration.groups.isEmpty)
        #expect(result.configuration.rules.isEmpty)
        #expect(result.report.serversImported == 2)
        #expect(result.report.notices.isEmpty)
    }

    @Test
    func duplicateServerNamesKeepTheFirstEntry() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Same
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
          - name: Same
            type: trojan
            server: 203.0.113.11
            port: 443
            password: p
        proxy-groups:
          - name: Pick
            type: select
            proxies:
              - Same
        """))
        // Both entries import; only the first is reachable by name, which is
        // what the notice warns about.
        #expect(result.configuration.servers.count == 2)
        let group = try #require(result.configuration.groups.first)
        #expect(group.memberIDs == [result.configuration.servers[0].id])
        let warning = try #require(result.report.notices.first { $0.severity == .warning })
        #expect(warning.section == .servers)
        #expect(warning.detail.contains("Same"))
    }

    @Test
    func anUnsupportedServerTypeIsReportedWithItsNameAndType() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
          - name: Odd
            type: quantum
            server: 203.0.113.11
            port: 443
        """))
        #expect(result.configuration.servers.count == 1)
        let dropped = try #require(result.report.notices.first { $0.severity == .dropped })
        #expect(dropped.section == .servers)
        #expect(dropped.detail.contains("Odd"))
        #expect(dropped.detail.contains("quantum"))
    }

    // MARK: - Groups

    @Test
    func groupMembersResolveByName() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
          - name: Beta
            type: trojan
            server: 203.0.113.11
            port: 443
            password: p
        proxy-groups:
          - name: Pick
            type: select
            proxies:
              - Beta
              - Alpha
        """))
        let group = try #require(result.configuration.groups.first)
        #expect(group.name == "Pick")
        #expect(group.kind == .select)
        // Order is preserved, and each id names the server that carried the
        // name in the document.
        #expect(group.memberIDs == [result.configuration.servers[1].id,
                                    result.configuration.servers[0].id])
        #expect(result.report.groupsImported == 1)
        #expect(result.report.notices.isEmpty)
    }

    @Test
    func aGroupMayContainAnotherGroup() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Inner
            type: select
            proxies:
              - Alpha
          - name: Outer
            type: select
            proxies:
              - Inner
              - Alpha
        """))
        #expect(result.configuration.groups.count == 2)
        let outer = try #require(result.configuration.groups.first { $0.name == "Outer" })
        let inner = try #require(result.configuration.groups.first { $0.name == "Inner" })
        #expect(outer.memberIDs == [inner.id, result.configuration.servers[0].id])
        #expect(result.report.notices.isEmpty)
    }

    @Test
    func aUrlTestGroupKeepsItsTargetAndInterval() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Fastest
            type: url-test
            url: http://probe.example.com/204
            interval: 600
            proxies:
              - Alpha
        """))
        let group = try #require(result.configuration.groups.first)
        #expect(group.kind == .urlTest)
        #expect(group.url == "http://probe.example.com/204")
        #expect(group.interval == 600)
    }

    @Test
    func anUnsupportedStrategyImportsAsASelector() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Auto
            type: fallback
            proxies:
              - Alpha
        """))
        let group = try #require(result.configuration.groups.first)
        #expect(group.kind == .select)
        #expect(group.memberIDs == [result.configuration.servers[0].id])
        let warning = try #require(result.report.notices.first { $0.severity == .warning })
        #expect(warning.section == .groups)
        #expect(warning.detail.contains("fallback"))
    }

    @Test
    func anUnknownGroupMemberIsDroppedButTheGroupSurvives() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Pick
            type: select
            proxies:
              - Ghost
              - Alpha
        """))
        let group = try #require(result.configuration.groups.first)
        #expect(group.memberIDs == [result.configuration.servers[0].id])
        let dropped = try #require(result.report.notices.first { $0.severity == .dropped })
        #expect(dropped.section == .groups)
        #expect(dropped.detail.contains("Ghost"))
    }

    @Test
    func aGroupThatCannotReachAServerIsLeftOut() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Lonely
            type: select
            proxies:
              - Missing
        """))
        #expect(result.configuration.groups.isEmpty)
        #expect(result.report.groupsImported == 0)
        let details = result.report.notices.map(\.detail)
        #expect(details.contains { $0.contains("no usable members") })
    }

    @Test
    func aGroupThatRefersToItselfLosesThatReference() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Loop
            type: select
            proxies:
              - Loop
              - Alpha
        """))
        let group = try #require(result.configuration.groups.first)
        #expect(group.memberIDs == [result.configuration.servers[0].id])
        #expect(result.report.notices.contains { $0.detail.contains("leads back to itself") })
    }

    @Test
    func aGroupCycleBetweenTwoGroupsIsBroken() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: First
            type: select
            proxies:
              - Second
              - Alpha
          - name: Second
            type: select
            proxies:
              - First
        """))
        // Both groups remain usable; only the reference that closed the loop is
        // removed, and which one that is must be the same on every run.
        #expect(result.configuration.groups.count == 2)
        let first = try #require(result.configuration.groups.first { $0.name == "First" })
        let second = try #require(result.configuration.groups.first { $0.name == "Second" })
        #expect(first.memberIDs == [result.configuration.servers[0].id])
        #expect(second.memberIDs == [first.id])
        let dropped = try #require(result.report.notices.first { $0.severity == .dropped })
        #expect(dropped.detail.contains("First"))
        #expect(dropped.detail.contains("Second"))
    }

    @Test
    func aDuplicateGroupDefinitionIsIgnored() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Pick
            type: select
            proxies:
              - Alpha
          - name: Pick
            type: select
            proxies:
              - Alpha
        """))
        #expect(result.configuration.groups.count == 1)
        #expect(result.report.notices.contains { $0.detail.contains("defined more than once") })
    }

    // MARK: - Rules

    @Test
    func ruleCriteriaAndActionsMap() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        rules:
          - DOMAIN,ads.example.com,REJECT
          - DOMAIN-SUFFIX,example.org,DIRECT
          - DOMAIN-KEYWORD,video,Alpha
          - IP-CIDR,198.51.100.0/24,Alpha
          - IP-CIDR6,2001:db8::/32,DIRECT
          - DST-PORT,8443,DIRECT
        """))
        let rules = result.configuration.rules
        #expect(rules.count == 6)
        let alphaID = result.configuration.servers[0].id

        #expect(rules[0].domains == ["ads.example.com"])
        #expect(rules[0].action == .reject)
        #expect(rules[0].outboundID == nil)

        #expect(rules[1].domainSuffixes == ["example.org"])
        #expect(rules[1].action == .direct)

        #expect(rules[2].domainKeywords == ["video"])
        #expect(rules[2].action == .route)
        #expect(rules[2].outboundID == alphaID)

        #expect(rules[3].ipCIDRs == ["198.51.100.0/24"])
        #expect(rules[4].ipCIDRs == ["2001:db8::/32"])
        #expect(rules[4].action == .direct)

        #expect(rules[5].ports == [8443])
        #expect(rules[5].action == .direct)
        #expect(result.report.notices.isEmpty)
    }

    @Test
    func aRuleTargetMayNameAGroup() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Pick
            type: select
            proxies:
              - Alpha
        rules:
          - DOMAIN,safe.example.com,Pick
        """))
        let group = try #require(result.configuration.groups.first)
        let rule = try #require(result.configuration.rules.first)
        #expect(rule.outboundID == group.id)
        #expect(rule.action == .route)
    }

    @Test
    func anUnsupportedRuleTypeIsDroppedRatherThanWidened() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        rules:
          - GEOIP,CN,DIRECT
          - PROCESS-NAME,curl,DIRECT
          - DOMAIN,keep.example.com,DIRECT
        """))
        // Only the rule that could be understood survives.
        #expect(result.configuration.rules.count == 1)
        #expect(result.configuration.rules[0].domains == ["keep.example.com"])
        // A dropped rule must never come back as a rule that matches everything.
        #expect(result.configuration.rules.allSatisfy { $0.matchesSomething })
        #expect(result.configuration.finalPolicy.isDefault)
        #expect(result.report.notices.filter { $0.severity == .dropped }.count == 2)
        #expect(result.report.notices.contains { $0.detail.contains("GEOIP") })
    }

    @Test
    func anIncompleteRuleIsDropped() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        rules:
          - DOMAIN,only-two-parts
          - DST-PORT,not-a-port,DIRECT
        """))
        #expect(result.configuration.rules.isEmpty)
        #expect(result.report.notices.filter { $0.severity == .dropped }.count == 2)
    }

    @Test
    func anUnknownRuleTargetStillRoutes() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        rules:
          - DOMAIN,example.com,Nowhere
        """))
        let rule = try #require(result.configuration.rules.first)
        // Routing somewhere is closer to the document than dropping the rule,
        // but the destination it named does not exist here.
        #expect(rule.action == .route)
        #expect(rule.outboundID == nil)
        let warning = try #require(result.report.notices.first { $0.severity == .warning })
        #expect(warning.detail.contains("Nowhere"))
    }

    // MARK: - Rule sets

    @Test
    func aRemoteRuleSetResolvesForTheRulesThatNameIt() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        rule-providers:
          ads:
            type: http
            url: https://example.com/ads.yaml
            interval: 3600
        rules:
          - RULE-SET,ads,REJECT
        """))
        let set = try #require(result.configuration.ruleSets.first)
        #expect(set.name == "ads")
        #expect(set.url == "https://example.com/ads.yaml")
        #expect(set.updateInterval == 3600)
        let rule = try #require(result.configuration.rules.first)
        #expect(rule.ruleSetTags == [set.id.uuidString])
        #expect(rule.action == .reject)
        #expect(result.report.ruleProvidersImported == 1)
        #expect(result.report.notices.isEmpty)
    }

    @Test
    func aRuleSetWithoutARemoteURLIsLeftOut() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        rule-providers:
          local:
            type: file
            path: ./local.yaml
        rules:
          - RULE-SET,local,REJECT
        """))
        #expect(result.configuration.ruleSets.isEmpty)
        // The rule that referred to it goes too, rather than becoming a rule
        // with no criterion.
        #expect(result.configuration.rules.isEmpty)
        #expect(result.report.notices.contains { $0.section == .ruleProviders })
        #expect(result.report.notices.contains { $0.section == .rules })
    }

    @Test
    func anInlineRuleSetIsReportedAsNotRemote() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        rule-providers:
          inline:
            type: inline
            payload:
              - example.com
        """))
        #expect(result.configuration.ruleSets.isEmpty)
        let dropped = try #require(result.report.notices.first { $0.section == .ruleProviders })
        #expect(dropped.detail.contains("not a remote list"))
    }

    // MARK: - The catch-all

    @Test
    func matchSetsTheFinalPolicyAndIsNotARule() throws {
        let direct = try #require(ConfigurationImport.parse(document(rules: "- MATCH,DIRECT")))
        #expect(direct.configuration.finalPolicy.kind == .direct)
        #expect(direct.configuration.finalPolicy.outboundID == nil)
        #expect(direct.configuration.rules.isEmpty)

        let reject = try #require(ConfigurationImport.parse(document(rules: "- MATCH,REJECT")))
        #expect(reject.configuration.finalPolicy.kind == .reject)
        #expect(reject.configuration.rules.isEmpty)
    }

    @Test
    func matchMayTargetAGroup() throws {
        let yaml = """
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        proxy-groups:
          - name: Pick
            type: select
            proxies:
              - Alpha
        rules:
          - MATCH,Pick
        """
        let result = try #require(ConfigurationImport.parse(yaml))
        let group = try #require(result.configuration.groups.first)
        #expect(result.configuration.finalPolicy.kind == .outbound)
        #expect(result.configuration.finalPolicy.outboundID == group.id)
        #expect(result.configuration.rules.isEmpty)
    }

    @Test
    func matchPointingAtNothingUsesTheActiveSelection() throws {
        let result = try #require(ConfigurationImport.parse(document(rules: "- MATCH,Missing")))
        #expect(result.configuration.finalPolicy.isDefault)
        let warning = try #require(result.report.notices.first { $0.severity == .warning })
        #expect(warning.detail.contains("Missing"))
    }

    // MARK: - DNS

    @Test
    func dnsNameserversHostsAndFakeIPMap() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        dns:
          nameserver:
            - 1.1.1.1
            - https://dns.example.com/dns-query
            - tls://dns.example.net:853
          hosts:
            "router.example":
              - 192.168.1.1
          enhanced-mode: fake-ip
          fake-ip-filter:
            - "*.local"
        """))
        let resolvers = result.configuration.dnsResolvers
        #expect(resolvers.count == 3)

        #expect(resolvers[0].kind == .udp)
        #expect(resolvers[0].server == "1.1.1.1")
        #expect(resolvers[0].serverPort == nil)

        #expect(resolvers[1].kind == .https)
        #expect(resolvers[1].server == "dns.example.com")
        #expect(resolvers[1].path == "/dns-query")

        #expect(resolvers[2].kind == .tls)
        #expect(resolvers[2].server == "dns.example.net")
        #expect(resolvers[2].serverPort == 853)

        #expect(result.configuration.dnsHosts.count == 1)
        #expect(result.configuration.dnsHosts[0].domain == "router.example")
        #expect(result.configuration.dnsHosts[0].address == "192.168.1.1")

        #expect(result.configuration.fakeIPEnabled)
        #expect(result.configuration.fakeIPExclusions == ["*.local"])
        #expect(result.report.dnsConfigured)
    }

    @Test
    func aDnsAddressWithAnUnknownSchemeIsLeftOut() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        dns:
          nameserver:
            - dhcp://en0
            - 9.9.9.9
        """))
        // The scheme is not an address, so it is reported rather than passed
        // through as a host named "dhcp".
        #expect(result.configuration.dnsResolvers.map(\.server) == ["9.9.9.9"])
        let warning = try #require(result.report.notices.first { $0.severity == .warning })
        #expect(warning.section == .dns)
        #expect(warning.detail.contains("dhcp://en0"))
    }

    @Test
    func dnsOptionsWithNoEquivalentAreNoted() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        dns:
          nameserver: 1.1.1.1
          fallback:
            - 8.8.8.8
          fake-ip-range: 198.18.0.1/16
        """))
        #expect(result.configuration.dnsResolvers.count == 1)
        let warnings = result.report.notices.filter { $0.severity == .warning }
        #expect(warnings.count == 2)
        #expect(warnings.contains { $0.detail.contains("fallback") })
        #expect(warnings.contains { $0.detail.contains("fake-ip-range") })
    }

    @Test
    func aDocumentWithNoDnsBlockLeavesTheDefaultResolvers() throws {
        let result = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        """))
        // Nothing parsed, so the model's own default stands rather than the
        // list being emptied.
        #expect(!result.report.dnsConfigured)
        #expect(result.configuration.dnsResolvers.map(\.server) == ["1.1.1.1"])
    }

    // MARK: - Name and report

    @Test
    func theDocumentNameIsOfferedToTheCaller() throws {
        let named = try #require(ConfigurationImport.parse("""
        name: My Setup
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        """))
        #expect(named.name == "My Setup")

        let anon = try #require(ConfigurationImport.parse("""
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        """))
        #expect(anon.name == nil)
    }

    @Test
    func reportSummarizesWhatItKept() {
        var report = ImportReport()
        #expect(report.summaryLine == "Nothing was imported.")
        #expect(!report.importedSomething)

        report.serversImported = 1
        report.groupsImported = 2
        report.rulesImported = 1
        report.ruleProvidersImported = 1
        report.dnsConfigured = true
        #expect(report.summaryLine == "1 server, 2 groups, 1 rule, 1 rule set, DNS settings.")
        #expect(report.importedSomething)
    }

    @Test
    func reportTracksTheWorstNotice() {
        var report = ImportReport()
        #expect(report.worstSeverity == nil)

        report.notices = [
            ImportNotice(severity: .info, section: .servers, detail: "a"),
            ImportNotice(severity: .warning, section: .dns, detail: "b"),
            ImportNotice(severity: .dropped, section: .rules, detail: "c"),
        ]
        #expect(report.worstSeverity == .dropped)
        #expect(report.droppedCount == 1)
    }

    // MARK: - Helpers

    /// A document with one server, so a test can be about the single section it
    /// cares about.
    private func document(rules: String) -> String {
        """
        proxies:
          - name: Alpha
            type: trojan
            server: 203.0.113.10
            port: 443
            password: p
        rules:
          \(rules)
        """
    }
}
