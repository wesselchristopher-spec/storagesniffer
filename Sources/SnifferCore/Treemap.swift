import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk). Produces rectangles whose areas are
/// proportional to the weights while keeping aspect ratios close to 1, which keeps small
/// items readable and big items easy to compare.
public enum Treemap {
    /// Lays out `weights` (sorted largest first) inside `rect`. Returns one rect per weight,
    /// in the same order. Zero or negative weights get an empty rect.
    public static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }

        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var i = 0
        let n = weights.count

        while i < n, weights[i] > 0 {
            let short = Double(min(remaining.width, remaining.height))
            var rowEnd = i + 1
            var rowSum = weights[i] * scale
            var best = worst(sum: rowSum, min: weights[i] * scale, max: weights[i] * scale, side: short)

            while rowEnd < n, weights[rowEnd] > 0 {
                let a = weights[rowEnd] * scale
                let candidate = worst(sum: rowSum + a, min: a, max: weights[i] * scale, side: short)
                if candidate > best { break }
                best = candidate
                rowSum += a
                rowEnd += 1
            }

            // Place the row along the shorter side of the remaining space.
            let horizontal = remaining.width >= remaining.height
            let thickness = CGFloat(rowSum / short)
            var offset: CGFloat = 0
            for j in i..<rowEnd {
                let length = CGFloat(weights[j] * scale / Double(thickness))
                if horizontal {
                    out[j] = CGRect(x: remaining.minX, y: remaining.minY + offset,
                                    width: thickness, height: length)
                } else {
                    out[j] = CGRect(x: remaining.minX + offset, y: remaining.minY,
                                    width: length, height: thickness)
                }
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            i = rowEnd
        }
        return out
    }

    /// Worst aspect ratio in a row with the given total area, laid along a side of length `side`.
    private static func worst(sum: Double, min: Double, max: Double, side: Double) -> Double {
        let s2 = sum * sum
        let w2 = side * side
        return Swift.max(w2 * max / s2, s2 / (w2 * min))
    }
}
