import SwiftUI
import SnifferCore

/// A flattened, nested treemap for one folder: its children, and for folders with room,
/// their children too. Parents come before their children in `tiles`.
struct TreemapLayout {
    struct Tile {
        var rect: CGRect
        var item: Item
        var depth: Int
        /// Index into `tiles` of the enclosing folder tile, or -1 at the top level.
        var parentIndex: Int
        var color: Color
        var label: Label
        enum Label {
            case none
            /// Folder name and size in a strip across the top.
            case header
            /// Name and size inside the tile.
            case inside
        }
    }

    var tiles: [Tile] = []
    var bounds: CGRect = .zero
    var folder: DirNode?

    static let maxDepth = 3
    static let maxTiles = 5000
    static let headerHeight: CGFloat = 18
    /// Items smaller than this many square points are folded into "smaller items".
    static let minArea: CGFloat = 36

    @MainActor
    static func build(folder: DirNode, bounds: CGRect, model: AppModel, dark: Bool) -> TreemapLayout {
        var layout = TreemapLayout(bounds: bounds, folder: folder)
        guard bounds.width > 4, bounds.height > 4 else { return layout }
        layout.tiles.reserveCapacity(1024)
        layout.place(items: model.items(of: folder), parent: folder, in: bounds.insetBy(dx: 1, dy: 1),
                     depth: 1, parentIndex: -1, hue: nil, model: model, dark: dark)
        return layout
    }

    @MainActor
    private mutating func place(items allItems: [Item], parent: DirNode, in rect: CGRect, depth: Int,
                                parentIndex: Int, hue: Double?, model: AppModel, dark: Bool) {
        let items = Self.foldSmallItems(allItems, parent: parent, area: rect.width * rect.height)
        guard !items.isEmpty else { return }
        let rects = Treemap.squarify(items.map { Double($0.size) }, in: rect)
        let gap: CGFloat = depth == 1 ? 1.5 : 1

        for (index, item) in items.enumerated() {
            guard tiles.count < Self.maxTiles else { return }
            let r = rects[index].insetBy(dx: gap / 2, dy: gap / 2)
            guard r.width >= 1, r.height >= 1 else { continue }

            let tileHue = hue ?? Palette.hue(at: index)
            var label: Tile.Label = .none
            let folder = item.folder
            let canNest = folder != nil && depth < Self.maxDepth && r.width > 40 && r.height > 34
            if canNest, depth == 1, r.height > 56, r.width > 70 {
                label = .header
            } else if r.width > 64, r.height > 30 {
                label = .inside
            }

            tiles.append(Tile(rect: r, item: item, depth: depth, parentIndex: parentIndex,
                              color: Palette.color(for: item, hue: tileHue, depth: depth, index: index, dark: dark),
                              label: label))
            let myIndex = tiles.count - 1

            if canNest, let folder {
                let pad: CGFloat = depth == 1 ? 3 : 2
                var inner = r.insetBy(dx: pad, dy: pad)
                if label == .header {
                    inner.origin.y += Self.headerHeight - pad
                    inner.size.height -= Self.headerHeight - pad
                } else if label == .inside {
                    // Leave the label readable: nested tiles only when there is plenty of room.
                    if r.width < 140 || r.height < 90 { continue }
                    tiles[myIndex].label = .header
                    inner.origin.y += Self.headerHeight - pad
                    inner.size.height -= Self.headerHeight - pad
                }
                guard inner.width > 8, inner.height > 8 else { continue }
                place(items: model.items(of: folder), parent: folder, in: inner, depth: depth + 1,
                      parentIndex: myIndex, hue: tileHue, model: model, dark: dark)
            }
        }
    }

    /// Keeps items that would be visible and folds the tail into one "smaller items" tile.
    private static func foldSmallItems(_ items: [Item], parent: DirNode, area: CGFloat) -> [Item] {
        let total = items.reduce(Int64(0)) { $0 + max($1.size, 0) }
        guard total > 0 else { return [] }
        let threshold = Double(minArea) / Double(area) * Double(total)
        var cut = items.count
        for (i, item) in items.enumerated() where Double(item.size) < threshold {
            cut = i
            break
        }
        let visible = items[..<cut].filter { $0.size > 0 }
        if cut >= items.count { return visible }
        let rest = items[cut...]
        let restSize = rest.reduce(Int64(0)) { $0 + $1.size }
        guard restSize > 0 else { return visible }
        if rest.count == 1, let only = rest.first { return visible + [only] }
        return visible + [Item(kind: .smaller(count: rest.count),
                               name: "\(rest.count.formatted()) smaller items",
                               size: restSize, parent: parent)]
    }

    /// The deepest tile under a point.
    func tileIndex(at point: CGPoint) -> Int? {
        for i in tiles.indices.reversed() where tiles[i].rect.contains(point) {
            return i
        }
        return nil
    }

    func index(of id: Item.ID) -> Int? {
        tiles.firstIndex { $0.item.id == id }
    }

    /// Rect of the tile for `dir`, or of its closest ancestor that has a tile.
    func focusRect(toward dir: DirNode) -> CGRect? {
        var node: DirNode? = dir
        while let n = node {
            if n === folder { return nil }
            if let i = index(of: .folder(n.id)) { return tiles[i].rect }
            node = n.parent
        }
        return nil
    }
}

enum Palette {
    /// Hues for top-level items, ordered so neighbours contrast.
    private static let hues: [Double] = [0.59, 0.08, 0.40, 0.83, 0.52, 0.00, 0.14, 0.68, 0.31, 0.93]

    static func hue(at index: Int) -> Double { hues[index % hues.count] }

    static func color(for item: Item, hue: Double, depth: Int, index: Int, dark: Bool) -> Color {
        switch item.kind {
        case .smaller:
            return Color(hue: hue, saturation: 0.06, brightness: dark ? 0.36 : 0.74)
        case .hidden(.purgeable):
            return Color(hue: 0.5, saturation: 0.12, brightness: dark ? 0.34 : 0.66)
        case .hidden(.other):
            return Color(white: dark ? 0.24 : 0.62)
        default:
            break
        }
        let isFile = !item.isFolder
        // Deeper levels get lighter and softer; files are slightly less saturated than folders.
        let d = Double(depth - 1)
        var saturation = (dark ? 0.58 : 0.55) - d * 0.09 - (isFile ? 0.08 : 0)
        var brightness = (dark ? 0.62 : 0.80) + d * (dark ? 0.07 : 0.05)
        // Small per-index variation so siblings of one colour stay distinguishable.
        let wobble = Double((index * 37) % 7) / 7.0 - 0.5
        brightness += wobble * 0.06
        saturation += wobble * 0.04
        return Color(hue: hue, saturation: max(0.08, saturation), brightness: min(0.97, brightness))
    }
}
