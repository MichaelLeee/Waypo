import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

struct TunnelEntry: TimelineEntry {
    let date: Date
    let status: NEVPNStatus
    let profileName: String
    let serverName: String?
}

/// Reads the status mirror and active profile from the shared store. The
/// widget process cannot load the profile manager, so the app and the
/// provider extension publish their status transitions instead.
private func currentEntry(date: Date) -> TunnelEntry {
    let store = TunnelStore()
    let status = store.loadStatusMirror().flatMap(NEVPNStatus.init(rawValue:)) ?? .disconnected
    let profile = store.loadProfileSet().activeProfile
    return TunnelEntry(
        date: date,
        status: status,
        profileName: profile?.name ?? "Default",
        serverName: profile?.configuration.servers.first?.name
    )
}

struct TunnelStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> TunnelEntry {
        currentEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (TunnelEntry) -> Void) {
        completion(currentEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TunnelEntry>) -> Void) {
        // Status transitions trigger explicit timeline reloads; this slow
        // refresh only catches transitions nothing observed.
        completion(Timeline(entries: [currentEntry(date: .now)],
                            policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct WaypoWidgetEntryView: View {
    var entry: TunnelEntry

    private var style: ConnectionStatusStyle {
        ConnectionStatusStyle(entry.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "shield.fill")
                    .font(.title3)
                    .foregroundStyle(style.color)
                Text(entry.profileName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(intent: ToggleTunnelIntent()) {
                    Image(systemName: entry.status == .connected ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(style.color)
                .accessibilityLabel(entry.status == .connected ? "Stop" : "Start")
            }
            Spacer(minLength: 0)
            Text(style.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(style.color)
            if let server = entry.serverName {
                Text(server)
                    .font(.caption)
                    .foregroundStyle(Palette.neutral)
                    .lineLimit(1)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct WaypoWidget: Widget {
    let kind: String = "WaypoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TunnelStatusProvider()) { entry in
            WaypoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Connection")
        .description("Shows the tunnel status and toggles it.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    WaypoWidget()
} timeline: {
    TunnelEntry(date: .now, status: .connected, profileName: "Home", serverName: "Tokyo")
    TunnelEntry(date: .now, status: .disconnected, profileName: "Home", serverName: nil)
}
