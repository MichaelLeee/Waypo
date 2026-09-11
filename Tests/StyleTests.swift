import NetworkExtension
import SwiftUI
import Testing

@Suite
struct LatencyLevelTests {
    @Test
    func thresholdsClassifyMilliseconds() {
        #expect(LatencyLevel(milliseconds: 0) == .fast)
        #expect(LatencyLevel(milliseconds: 149) == .fast)
        #expect(LatencyLevel(milliseconds: 150) == .medium)
        #expect(LatencyLevel(milliseconds: 399) == .medium)
        #expect(LatencyLevel(milliseconds: 400) == .slow)
        #expect(LatencyLevel(milliseconds: 5_000) == .slow)
    }

    @Test
    func labelUsesOneFormat() {
        #expect(LatencyLevel.label(milliseconds: 0) == "0 ms")
        #expect(LatencyLevel.label(milliseconds: 149) == "149 ms")
        #expect(LatencyLevel.label(milliseconds: 1234.6) == "1235 ms")
    }

    @Test
    func levelsHaveDistinctColours() {
        let colors = LatencyLevel.allCases.map(\.color)
        #expect(Set(colors).count == LatencyLevel.allCases.count)
        #expect(LatencyLevel.fast.color == Palette.positive)
        #expect(LatencyLevel.medium.color == Palette.caution)
        #expect(LatencyLevel.slow.color == Palette.negative)
    }
}

@Suite
struct ConnectionStatusStyleTests {
    /// Every case `NEVPNStatus` declares. `@unknown default` is covered
    /// separately by the exhaustive switch in `WaypoStyle.swift`.
    private static let allStatuses: [NEVPNStatus] = [
        .invalid, .disconnected, .connecting, .connected, .disconnecting, .reasserting,
    ]

    @Test
    func everyStatusHasPresentation() {
        for status in Self.allStatuses {
            let style = ConnectionStatusStyle(status)
            #expect(!style.label.isEmpty)
            #expect(!style.symbol.isEmpty)
        }
    }

    @Test
    func labelsAreDistinct() {
        let labels = Self.allStatuses.map { ConnectionStatusStyle($0).label }
        #expect(Set(labels).count == Self.allStatuses.count)
    }

    /// The identifier is what a script compares against, so it is spelled out
    /// here rather than only being checked for uniqueness: renaming one is a
    /// change to a documented interface.
    @Test
    func identifiersAreStableAndDistinct() {
        let identifiers = Self.allStatuses.map { ConnectionStatusStyle($0).identifier }
        #expect(Set(identifiers).count == Self.allStatuses.count)
        #expect(ConnectionStatusStyle(.connected).identifier == "connected")
        #expect(ConnectionStatusStyle(.connecting).identifier == "connecting")
        #expect(ConnectionStatusStyle(.disconnecting).identifier == "disconnecting")
        #expect(ConnectionStatusStyle(.disconnected).identifier == "disconnected")
        #expect(ConnectionStatusStyle(.reasserting).identifier == "reasserting")
        #expect(ConnectionStatusStyle(.invalid).identifier == "invalid")
    }

    @Test
    func coloursTrackStatus() {
        #expect(ConnectionStatusStyle(.connected).color == Palette.positive)
        #expect(ConnectionStatusStyle(.connecting).color == Palette.caution)
        #expect(ConnectionStatusStyle(.disconnecting).color == Palette.caution)
        #expect(ConnectionStatusStyle(.reasserting).color == Palette.caution)
        #expect(ConnectionStatusStyle(.disconnected).color == Palette.neutral)
        #expect(ConnectionStatusStyle(.invalid).color == Palette.neutral)
    }

    @Test
    func busyOnlyWhileInMotion() {
        #expect(ConnectionStatusStyle(.connecting).isBusy)
        #expect(ConnectionStatusStyle(.disconnecting).isBusy)
        #expect(ConnectionStatusStyle(.reasserting).isBusy)
        #expect(!ConnectionStatusStyle(.connected).isBusy)
        #expect(!ConnectionStatusStyle(.disconnected).isBusy)
        #expect(!ConnectionStatusStyle(.invalid).isBusy)
    }
}

@Suite
struct TransportStyleTests {
    /// The transport identifiers `ServerImport` can produce, plus `direct`,
    /// which the manual editor offers.
    private static let importerTransports = [
        "direct", "trojan", "vless", "vmess", "shadowsocks",
        "hysteria2", "tuic", "anytls", "wireguard", "shadowtls",
    ]

    @Test
    func allIsUniqueAndCoversTheImporter() {
        #expect(Set(TransportStyle.all).count == TransportStyle.all.count)
        for transport in Self.importerTransports {
            #expect(TransportStyle.all.contains(transport))
        }
    }

    @Test
    func everyKnownTransportIsNamedAndDrawn() {
        for transport in TransportStyle.all {
            // The display name must not fall through to the raw identifier,
            // and the symbol must not fall through to the unknown glyph.
            #expect(TransportStyle.displayName(for: transport) != transport)
            #expect(TransportStyle.symbol(for: transport) != "questionmark.circle")
        }
    }

    @Test
    func lookupIgnoresCase() {
        for transport in TransportStyle.all {
            #expect(TransportStyle.displayName(for: transport.uppercased())
                    == TransportStyle.displayName(for: transport))
            #expect(TransportStyle.symbol(for: transport.uppercased())
                    == TransportStyle.symbol(for: transport))
        }
    }

    @Test
    func unknownTransportFallsBackToItsIdentifier() {
        #expect(TransportStyle.displayName(for: "quic-plus") == "quic-plus")
        #expect(TransportStyle.symbol(for: "quic-plus") == "questionmark.circle")
    }
}
