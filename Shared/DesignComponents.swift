import SwiftUI

/// The tone a `StatusPill` speaks in.
enum PillTone {
    case positive
    case caution
    case negative
    case neutral
    case accent

    var color: Color {
        switch self {
        case .positive: Palette.positive
        case .caution: Palette.caution
        case .negative: Palette.negative
        case .neutral: Palette.neutral
        case .accent: Palette.accent
        }
    }
}

/// A small tinted badge. Covers the three ways the app used to mark a row:
/// the "In Use" text, the filled trailing checkmark, and the plain checkmark.
struct StatusPill: View {
    var text: String?
    var systemImage: String?
    var tone: PillTone

    init(_ text: String? = nil, systemImage: String? = nil, tone: PillTone = .neutral) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            if let text {
                Text(text)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, text == nil ? 3 : 6)
        .padding(.vertical, 2)
        .background(tone.color.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: Metrics.pillCornerRadius, style: .continuous))
    }
}

/// The one empty state. Standardising on this form keeps the screen's toolbar
/// reachable, which an `.overlay`-based empty state hides.
struct WaypoEmptyState: View {
    var title: String
    var systemImage: String
    var message: String?

    init(_ title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        ContentUnavailableView(title,
                               systemImage: systemImage,
                               description: message.map { Text($0) })
    }
}

/// The one error presentation: footnote, negative tone, alignment left to the
/// surface that owns the layout.
struct ErrorText: View {
    var message: String
    var alignment: TextAlignment

    init(_ message: String, alignment: TextAlignment = .center) {
        self.message = message
        self.alignment = alignment
    }

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(Palette.negative)
            .multilineTextAlignment(alignment)
    }
}

/// A section header with a trailing detail label, used by the group list.
struct GroupHeaderRow: View {
    var title: String
    var detail: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.neutral)
        }
    }
}

extension View {
    /// The Cancel/Save pair every editor sheet carries.
    func editorToolbar(isSaveDisabled: Bool = false,
                       onSave: @escaping () -> Void) -> some View {
        modifier(EditorToolbar(isSaveDisabled: isSaveDisabled, onSave: onSave))
    }

    /// Inline titles on iOS; a no-op on macOS, which has no such mode.
    @ViewBuilder
    func inlineTitleOnIOS() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

private struct EditorToolbar: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    var isSaveDisabled: Bool
    var onSave: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: onSave)
                    .disabled(isSaveDisabled)
            }
        }
    }
}
