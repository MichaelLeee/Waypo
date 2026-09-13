import SwiftUI

/// The account reading a remote source reported, shown the same way wherever a
/// profile that keeps itself current is on screen: right after a fetch in the
/// import sheet, and for as long as the profile exists in the server list.
///
/// Every field is optional because sources vary in what they send. A reading
/// with nothing in it says so rather than rendering an empty block, and a
/// failed refresh is shown beside the last good reading rather than replacing
/// it — the entries the source already gave are still in use.
struct SubscriptionSummary: View {
    var userInfo: SubscriptionUserInfo?
    var lastUpdated: Date?
    var lastError: String?

    var body: some View {
        if let lastError {
            ErrorText(lastError, alignment: .leading)
        }
        if let lastUpdated {
            row("Last Updated") {
                Text(lastUpdated, style: .relative)
            }
        }
        if let userInfo {
            if let used = userInfo.usedText {
                row("Used") {
                    Text(used + (userInfo.totalText.map { " of \($0)" } ?? ""))
                        .monospacedDigit()
                }
            }
            if let fraction = userInfo.usedFraction {
                ProgressView(value: fraction)
                    .tint(fraction >= 0.9 ? Palette.caution : Palette.accent)
            }
            if let remaining = userInfo.remainingText {
                row("Remaining") {
                    Text(remaining).monospacedDigit()
                }
            }
            if let expiry = userInfo.expiryText {
                row("Expires") {
                    HStack(spacing: 6) {
                        Text(expiry)
                        if userInfo.isExpired {
                            StatusPill("Expired", tone: .negative)
                        }
                    }
                }
            }
        }
        if userInfo == nil, lastUpdated == nil, lastError == nil {
            Text("This source reported nothing about the account.")
                .font(.footnote)
                .foregroundStyle(Palette.neutral)
        }
    }

    private func row<Value: View>(_ title: String,
                                  @ViewBuilder value: () -> Value) -> some View {
        HStack {
            Text(title)
            Spacer()
            value()
        }
    }
}
