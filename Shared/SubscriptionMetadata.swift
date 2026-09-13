import Foundation

/// What a provider reports about the account alongside a fetch: how much has
/// been used, how much there is, and when it runs out.
///
/// The header is not a standard and providers vary in which fields they send,
/// so every field is optional and the type is only produced when at least one
/// of them parsed. Counts are bytes; the expiry is a Unix timestamp.
struct SubscriptionUserInfo: Codable, Hashable, Sendable {
    var uploadBytes: Int64?
    var downloadBytes: Int64?
    var totalBytes: Int64?
    var expiresAt: Date?
    /// When this reading was taken, so a stale figure can be labelled as one.
    var updatedAt: Date?

    /// Parses the `upload=…; download=…; total=…; expire=…` line.
    ///
    /// Unknown keys are ignored rather than rejected: providers add their own
    /// (`reset_day`, `plan`, …) and a new one must not cost the whole line.
    /// Returns nil when none of the four known fields parsed, so a caller can
    /// tell "no information" from "zero used".
    static func parse(_ headerValue: String?, updatedAt: Date = Date()) -> SubscriptionUserInfo? {
        guard let headerValue, !headerValue.isEmpty else { return nil }
        var upload: Int64?
        var download: Int64?
        var total: Int64?
        var expires: Date?
        for field in headerValue.split(separator: ";") {
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = String(field[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(field[field.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "upload": upload = byteCount(value) ?? upload
            case "download": download = byteCount(value) ?? download
            case "total": total = byteCount(value) ?? total
            case "expire": expires = timestamp(value) ?? expires
            default: continue
            }
        }
        guard upload != nil || download != nil || total != nil || expires != nil else { return nil }
        return SubscriptionUserInfo(uploadBytes: upload, downloadBytes: download,
                                    totalBytes: total, expiresAt: expires, updatedAt: updatedAt)
    }

    var usedBytes: Int64? {
        guard uploadBytes != nil || downloadBytes != nil else { return nil }
        return (uploadBytes ?? 0) + (downloadBytes ?? 0)
    }

    /// Never negative: a provider may report more used than the plan allows,
    /// and "−2 GB remaining" tells the user nothing they can act on.
    var remainingBytes: Int64? {
        guard let totalBytes, let usedBytes else { return nil }
        return max(0, totalBytes - usedBytes)
    }

    /// Clamped, because it drives a progress indicator that cannot overrun.
    var usedFraction: Double? {
        guard let totalBytes, totalBytes > 0, let usedBytes else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    var usedText: String? { bytesText(usedBytes) }
    var totalText: String? { bytesText(totalBytes) }
    var remainingText: String? { bytesText(remainingBytes) }

    var expiryText: String? {
        guard let expiresAt else { return nil }
        return expiresAt.formatted(date: .abbreviated, time: .omitted)
    }

    private func bytesText(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return bytes.formatted(.byteCount(style: .memory))
    }

    /// Values arrive as integers, but a provider is free to send `1.5e9`, and
    /// parsing through `Double` is what makes the large counts survive.
    private static func byteCount(_ text: String) -> Int64? {
        guard let value = Double(text), value.isFinite, value >= 0,
              value <= Double(Int64.max) else { return nil }
        return Int64(value)
    }

    /// Seconds, except when the magnitude makes it milliseconds: no date a
    /// provider could mean is this far away in seconds, and several providers
    /// send the millisecond form.
    private static func timestamp(_ text: String) -> Date? {
        guard let value = Double(text), value.isFinite, value > 0 else { return nil }
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}
