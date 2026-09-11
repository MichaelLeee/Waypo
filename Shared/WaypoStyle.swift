import Foundation
import NetworkExtension
import SwiftUI

/// The app's colour vocabulary. Every colour used anywhere in the UI resolves
/// through here, so the palette can be retuned in one place. System colours are
/// used deliberately: they already adapt to light and dark appearance.
enum Palette {
    /// The app-wide accent, applied at the root with `.tint(Palette.accent)`.
    static let accent = Color(red: 0.24, green: 0.50, blue: 0.95)

    /// A healthy, finished, or fast state.
    static let positive = Color.green
    /// A state that is in motion, degraded, or needs attention.
    static let caution = Color.orange
    /// A failure state.
    static let negative = Color.red
    /// An inactive or unknown state.
    static let neutral = Color.secondary
}

/// Fixed geometry shared by more than one surface. Sizes that should follow the
/// user's text-size setting live at the view that uses them, as `@ScaledMetric`.
enum Metrics {
    /// Leading glyph in a list row.
    static let rowIconSize: CGFloat = 28
    /// Large status glyph in the connection card.
    static let heroIconSize: CGFloat = 40
    /// Glyph drawn inside the connect/stop button.
    static let actionIconSize: CGFloat = 28
    /// Diameter of the connect/stop button.
    static let actionButtonSize: CGFloat = 84
    /// Corner radius of the small inline pills.
    static let pillCornerRadius: CGFloat = 6
}

/// One latency scale for the whole app. Before this existed the same two
/// thresholds were copied into the server list and the group member list, with
/// two different number formats.
enum LatencyLevel: CaseIterable {
    case fast
    case medium
    case slow

    static let fastThreshold: Double = 150
    static let slowThreshold: Double = 400

    init(milliseconds: Double) {
        if milliseconds < Self.fastThreshold {
            self = .fast
        } else if milliseconds < Self.slowThreshold {
            self = .medium
        } else {
            self = .slow
        }
    }

    var color: Color {
        switch self {
        case .fast: Palette.positive
        case .medium: Palette.caution
        case .slow: Palette.negative
        }
    }

    /// The single latency format. `String(format:)` with no locale argument does
    /// not localise, so this is stable regardless of the user's region.
    static func label(milliseconds: Double) -> String {
        String(format: "%.0f ms", milliseconds)
    }
}

/// How a connection status is presented. The same transitions previously
/// carried four slightly different labels and colours across the app, the
/// widget, and the control.
struct ConnectionStatusStyle {
    var status: NEVPNStatus

    init(_ status: NEVPNStatus) {
        self.status = status
    }

    var label: String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnecting: "Disconnecting…"
        case .disconnected: "Disconnected"
        case .invalid: "Profile not installed"
        case .reasserting: "Reasserting…"
        @unknown default: "Unknown"
        }
    }

    var color: Color {
        switch status {
        case .connected: Palette.positive
        case .connecting, .disconnecting, .reasserting: Palette.caution
        default: Palette.neutral
        }
    }

    /// Status glyph. The connect/stop action glyph stays local to each surface,
    /// because the widget and the control use filled variants.
    var symbol: String {
        switch status {
        case .connected: "checkmark.shield.fill"
        case .connecting, .disconnecting, .reasserting: "arrow.triangle.2.circlepath"
        case .disconnected: "shield.slash"
        case .invalid: "exclamationmark.triangle"
        @unknown default: "questionmark.circle"
        }
    }

    var isBusy: Bool {
        status == .connecting || status == .disconnecting || status == .reasserting
    }
}

/// How each transport is named and drawn. The transport identifier is what the
/// engine understands; this turns it into something a person reads.
enum TransportStyle {
    /// Every transport the importer can produce, in picker order.
    static let all = [
        "direct",
        "trojan",
        "vless",
        "shadowsocks",
        "hysteria2",
        "tuic",
        "vmess",
        "wireguard",
        "anytls",
        "shadowtls",
    ]

    static func displayName(for transport: String) -> String {
        switch transport.lowercased() {
        case "direct": "Direct"
        case "trojan": "Trojan"
        case "vless": "VLESS"
        case "vmess": "VMess"
        case "shadowsocks": "Shadowsocks"
        case "hysteria2": "Hysteria2"
        case "tuic": "TUIC"
        case "anytls": "AnyTLS"
        case "wireguard": "WireGuard"
        case "shadowtls": "Shadow-TLS"
        default: transport
        }
    }

    static func symbol(for transport: String) -> String {
        switch transport.lowercased() {
        case "direct": "arrow.right"
        case "trojan": "shield"
        case "vless": "bolt"
        case "vmess": "envelope"
        case "shadowsocks": "eye.slash"
        case "hysteria2": "wind"
        case "tuic": "drop"
        case "anytls": "lock"
        case "wireguard": "point.3.connected.trianglepath.dotted"
        case "shadowtls": "circle.lefthalf.filled"
        default: "questionmark.circle"
        }
    }
}
