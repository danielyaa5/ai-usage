import Foundation

/// The dashboard's number and time formats, so the widgets read the same as the page.
public enum Format {
    public static func usd(_ value: Double?) -> String {
        guard let value else { return "–" }
        if value == 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        if value < 100 { return "$" + String(format: "%.2f", value) }
        return "$" + grouped(Int(value.rounded()))
    }

    public static func tokens(_ value: Int) -> String {
        let v = Double(value)
        if value == 0 { return "0" }
        if v >= 1e9 { return String(format: v >= 1e10 ? "%.0fB" : "%.1fB", v / 1e9) }
        if v >= 1e6 { return String(format: v >= 1e7 ? "%.0fM" : "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: v >= 1e4 ? "%.0fK" : "%.1fK", v / 1e3) }
        return String(value)
    }

    public static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "2d 1h", "4h 52m" or "5m" until `date`; nil once it has passed.
    public static func remaining(until date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// "resets in 2d 1h", or "reset due" once the time has passed, as on the dashboard.
    public static func resets(_ date: Date?, now: Date = Date()) -> String {
        guard date != nil else { return "" }
        guard let left = remaining(until: date, now: now) else { return "reset due" }
        return "resets in \(left)"
    }

    /// "just now", "6 min ago", "21 h ago", "3 d ago".
    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min ago" }
        if seconds < 86400 { return "\(Int((seconds / 3600).rounded())) h ago" }
        return "\(Int((seconds / 86400).rounded())) d ago"
    }
}
