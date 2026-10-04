import CoreGraphics
import Testing
@testable import SnifferCore

@Suite struct TreemapTests {
    @Test func areasAreProportionalAndFillTheRect() {
        let weights: [Double] = [600, 300, 200, 100, 50, 25, 10, 5]
        let rect = CGRect(x: 10, y: 20, width: 800, height: 500)
        let rects = Treemap.squarify(weights, in: rect)
        let total = weights.reduce(0, +)
        let area = Double(rect.width * rect.height)

        var covered = 0.0
        for (w, r) in zip(weights, rects) {
            let a = Double(r.width * r.height)
            #expect(abs(a - w / total * area) < 1)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
            covered += a
        }
        #expect(abs(covered - area) < 1)
    }

    @Test func rectsDoNotOverlap() {
        let weights = (1...40).map { Double(1000 / $0) }
        let rects = Treemap.squarify(weights, in: CGRect(x: 0, y: 0, width: 640, height: 480))
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func aspectRatiosStayReasonable() {
        let rects = Treemap.squarify([10, 10, 10, 10, 10, 10], in: CGRect(x: 0, y: 0, width: 600, height: 400))
        for r in rects {
            #expect(max(r.width / r.height, r.height / r.width) < 3)
        }
    }

    @Test func zeroWeightsGetEmptyRects() {
        let rects = Treemap.squarify([5, 0, 0], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(rects[0].width == 100)
        #expect(rects[1] == .zero)
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }

    @Test func formatUsesDecimalUnits() {
        #expect(Format.bytes(999) == "999 bytes")
        #expect(Format.bytes(1_500_000) == "1.5 MB")
        #expect(Format.bytes(123_000_000_000) == "123 GB")
        #expect(Format.percent(1, of: 10_000) == "<0.1%")
    }
}
