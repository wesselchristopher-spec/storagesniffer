import Foundation

public enum Format {
    /// Decimal units, matching Finder and "About This Mac".
    public static func bytes(_ value: Int64) -> String {
        let v = Double(max(value, 0))
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var i = 0
        var x = v
        while x >= 1000 && i < units.count - 1 {
            x /= 1000
            i += 1
        }
        if i == 0 { return "\(Int(v)) bytes" }
        let digits = x >= 100 ? 0 : 1
        return String(format: "%.\(digits)f %@", x, units[i])
    }

    public static func count(_ value: Int64) -> String {
        value.formatted(.number)
    }

    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "—" }
        let p = Double(part) / Double(whole) * 100
        if p > 0 && p < 0.1 { return "<0.1%" }
        return String(format: p >= 10 ? "%.0f%%" : "%.1f%%", p)
    }
}
