import SwiftUI
import SnifferCore

/// Draws the current folder as a nested treemap. Clicking a folder zooms into it.
struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    @ViewState private var layout = TreemapLayout()
    @ViewState private var transition: Transition?
    @ViewState private var morph: Morph?
    @ViewState private var hoverIndex: Int?
    @ViewState private var size: CGSize = .zero

    private struct Transition {
        var outer: TreemapLayout
        var inner: TreemapLayout
        /// Rect of the inner folder within the outer layout.
        var focus: CGRect
        var zoomIn: Bool
        var start: Date
        static let duration: TimeInterval = 0.22
    }

    /// Animates tiles from their previous rects when sizes change in place, e.g. while a scan
    /// discovers more data or after moving something to the Trash.
    private struct Morph {
        var from: [Item.ID: CGRect]
        var start: Date
        static let duration: TimeInterval = 0.65
    }

    private struct LayoutKey: Equatable {
        var folder: ObjectIdentifier?
        var size: CGSize
        var revision: Int
        var dark: Bool
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: transition == nil && morph == nil)) { timeline in
                Canvas(rendersAsynchronously: false) { context, canvasSize in
                    draw(in: &context, now: timeline.date)
                }
            }
            .onAppear { size = geo.size }
            .onChange(of: geo.size) { _, new in size = new }
        }
        .overlay { emptyState }
        .onChange(of: layoutKey, initial: true) { old, new in rebuild(old: old, new: new) }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): setHover(layout.tileIndex(at: p))
            case .ended: setHover(nil)
            }
        }
        .onTapGesture { location in click(at: location) }
        .contextMenu {
            if let item = model.hovered {
                ItemMenu(item: item)
            }
        }
        .accessibilityLabel("Treemap of \(model.current.map(model.displayName(of:)) ?? "folder")")
    }

    private var layoutKey: LayoutKey {
        LayoutKey(folder: model.current?.id, size: size, revision: model.layoutRevision,
                  dark: colorScheme == .dark)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let current = model.current, current.isListed || current.state != .pending,
           layout.tiles.isEmpty, current.isComplete {
            ContentUnavailableView {
                Label(current.state == .denied ? "Can’t Read This Folder" : "Nothing Here",
                      systemImage: current.state == .denied ? "lock.fill" : "folder")
            } description: {
                Text(current.state == .denied
                     ? "macOS blocked access. Grant Full Disk Access to see what’s inside."
                     : "This folder doesn’t use any disk space.")
            }
        }
    }

    // MARK: Layout

    private func rebuild(old: LayoutKey, new: LayoutKey) {
        guard let folder = model.current else {
            layout = TreemapLayout()
            return
        }
        let bounds = CGRect(origin: .zero, size: new.size)
        let next = TreemapLayout.build(folder: folder, bounds: bounds, model: model, dark: new.dark)

        if old.folder != new.folder, old.size == new.size, let previous = layout.folder,
           !layout.tiles.isEmpty {
            if folder.isDescendant(of: previous), let focus = layout.focusRect(toward: folder) {
                transition = Transition(outer: layout, inner: next, focus: focus, zoomIn: true, start: .now)
            } else if previous.isDescendant(of: folder), let focus = next.focusRect(toward: previous) {
                transition = Transition(outer: next, inner: layout, focus: focus, zoomIn: false, start: .now)
            } else {
                transition = nil
            }
            morph = nil
        } else if old.folder == new.folder, old.size == new.size, !layout.tiles.isEmpty {
            // Start from where tiles are on screen right now, even mid-animation.
            var from: [Item.ID: CGRect] = [:]
            from.reserveCapacity(layout.tiles.count)
            for tile in animatedTiles(at: .now).tiles {
                from[tile.item.id] = tile.rect
            }
            morph = Morph(from: from, start: .now)
        }
        layout = next
        hoverIndex = nil
    }

    private func setHover(_ index: Int?) {
        guard index != hoverIndex else { return }
        hoverIndex = index
        model.hovered = index.map { layout.tiles[$0].item }
    }

    private func click(at point: CGPoint) {
        guard let i = layout.tileIndex(at: point) else { return }
        let item = layout.tiles[i].item
        switch item.kind {
        case .folder(let dir):
            model.selection = nil
            model.open(dir)
        case .file:
            model.open(item)
        case .smaller:
            model.open(item.parent)
        case .hidden:
            model.selection = item.id
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, now: Date) {
        guard let t = transition else {
            let (tiles, alphas) = animatedTiles(at: now)
            drawTiles(tiles, alphas: alphas, in: &context, labels: true, highlights: true)
            return
        }
        let elapsed = now.timeIntervalSince(t.start)
        if elapsed >= Transition.duration {
            DispatchQueue.main.async { transition = nil }
        }
        let eased = Spring.settle(elapsed, duration: Transition.duration)
        let q = t.zoomIn ? eased : 1 - eased
        let bounds = layout.bounds
        let visible = lerp(t.focus, bounds, CGFloat(q))

        var outer = context
        outer.concatenate(transform(from: t.focus, to: visible))
        drawTiles(t.outer.tiles, alphas: nil, in: &outer, labels: false, highlights: false)

        var inner = context
        inner.clip(to: Path(visible))
        inner.opacity = q
        inner.concatenate(transform(from: bounds, to: visible))
        drawTiles(t.inner.tiles, alphas: nil, in: &inner, labels: false, highlights: false)
    }

    /// Tiles at their on-screen positions: interpolated with a spring while morphing.
    /// New tiles grow out of their own centre and fade in.
    private func animatedTiles(at now: Date) -> (tiles: [TreemapLayout.Tile], alphas: [Double]?) {
        guard let m = morph else { return (layout.tiles, nil) }
        let elapsed = now.timeIntervalSince(m.start)
        if elapsed >= Morph.duration {
            DispatchQueue.main.async { if morph?.start == m.start { morph = nil } }
            return (layout.tiles, nil)
        }
        let p = CGFloat(Spring.bouncy(elapsed))
        let fade = min(1, elapsed / (Morph.duration * 0.5))
        var tiles = layout.tiles
        var alphas = [Double](repeating: 1, count: tiles.count)
        for i in tiles.indices {
            let target = tiles[i].rect
            if let from = m.from[tiles[i].item.id] {
                tiles[i].rect = lerp(from, target, p)
            } else {
                let seed = CGRect(x: target.midX, y: target.midY, width: 0, height: 0)
                tiles[i].rect = lerp(seed, target, p)
                alphas[i] = fade
            }
        }
        return (tiles, alphas)
    }

    private func drawTiles(_ tiles: [TreemapLayout.Tile], alphas: [Double]?, in context: inout GraphicsContext,
                           labels: Bool, highlights: Bool) {
        let shine = Gradient(colors: [.white.opacity(0.22), .white.opacity(0.0)])
        let baseOpacity = context.opacity
        for (index, tile) in tiles.enumerated() {
            let r = tile.rect
            guard r.width > 0.5, r.height > 0.5 else { continue }
            let alpha = alphas?[index] ?? 1
            context.opacity = baseOpacity * alpha
            let radius = min(tile.depth == 1 ? 5 : 3, r.width / 3, r.height / 3)
            let path = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
            context.fill(path, with: .color(tile.color))
            if r.width > 6 && r.height > 6 {
                context.fill(path, with: .linearGradient(
                    shine, startPoint: CGPoint(x: r.minX, y: r.minY),
                    endPoint: CGPoint(x: r.minX, y: r.minY + min(r.height, 120))))
            }
            if case .hidden(let unseen) = tile.item.kind, unseen != .free {
                drawHatching(in: r, path: path, context: &context)
            }
        }

        if labels {
            for (index, tile) in tiles.enumerated() where tile.label != .none {
                context.opacity = baseOpacity * (alphas?[index] ?? 1)
                drawLabel(tile, in: &context)
            }
        }
        context.opacity = baseOpacity

        guard highlights else { return }
        if let id = model.selection, let i = tiles.firstIndex(where: { $0.item.id == id }) {
            let r = tiles[i].rect
            context.stroke(Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 4, style: .continuous),
                           with: .color(.accentColor), lineWidth: 2.5)
        }
        if let i = hoverIndex, i < tiles.count {
            let tile = tiles[i]
            let path = Path(roundedRect: tile.rect, cornerRadius: tile.depth == 1 ? 5 : 3, style: .continuous)
            context.fill(path, with: .color(.white.opacity(0.14)))
            context.stroke(Path(roundedRect: tile.rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4,
                                style: .continuous),
                           with: .color(.white.opacity(0.95)), lineWidth: 1.5)
        }
    }

    private func drawHatching(in r: CGRect, path: Path, context: inout GraphicsContext) {
        var lines = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            lines.move(to: CGPoint(x: x, y: r.maxY))
            lines.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 9
        }
        var c = context
        c.clip(to: path)
        c.stroke(lines, with: .color(.white.opacity(0.12)), lineWidth: 3)
    }

    private func drawLabel(_ tile: TreemapLayout.Tile, in context: inout GraphicsContext) {
        let r = tile.rect
        let size = Format.bytes(tile.item.size)
        switch tile.label {
        case .none:
            return
        case .header:
            let area = CGRect(x: r.minX + 6, y: r.minY + 2, width: r.width - 12, height: TreemapLayout.headerHeight - 3)
            let sizeWidth = CGFloat(size.count) * 6.0 + 8
            let showSize = area.width > sizeWidth + 40
            let nameWidth = showSize ? area.width - sizeWidth : area.width
            let name = truncate(tile.item.name, width: nameWidth, charWidth: 6.6)
            drawText(Text(name).font(.system(size: 11, weight: .semibold)),
                     at: CGPoint(x: area.minX, y: area.midY), anchor: .leading, in: &context)
            if showSize {
                drawText(Text(size).font(.system(size: 10, weight: .medium)).monospacedDigit(),
                         at: CGPoint(x: area.maxX, y: area.midY), anchor: .trailing, in: &context, opacity: 0.85)
            }
        case .inside:
            let x = r.minX + 6
            let width = r.width - 12
            let big = r.width > 160 && r.height > 70 && tile.depth == 1
            let nameFont: Font = .system(size: big ? 13 : 11, weight: .semibold)
            let name = truncate(tile.item.name, width: width, charWidth: big ? 7.6 : 6.6)
            drawText(Text(name).font(nameFont), at: CGPoint(x: x, y: r.minY + (big ? 13 : 11)),
                     anchor: .leading, in: &context)
            if r.height > (big ? 46 : 36) {
                drawText(Text(size).font(.system(size: big ? 12 : 10, weight: .medium)).monospacedDigit(),
                         at: CGPoint(x: x, y: r.minY + (big ? 30 : 25)), anchor: .leading, in: &context, opacity: 0.85)
            }
        }
    }

    private func drawText(_ text: Text, at point: CGPoint, anchor: UnitPoint,
                          in context: inout GraphicsContext, opacity: Double = 1) {
        let shadow = context.resolve(text.foregroundStyle(.black.opacity(0.35 * opacity)))
        context.draw(shadow, at: CGPoint(x: point.x, y: point.y + 0.75), anchor: anchor)
        let resolved = context.resolve(text.foregroundStyle(.white.opacity(opacity)))
        context.draw(resolved, at: point, anchor: anchor)
    }

    private func truncate(_ s: String, width: CGFloat, charWidth: CGFloat) -> String {
        let maxChars = Int(width / charWidth)
        if s.count <= maxChars { return s }
        if maxChars < 4 { return "" }
        return String(s.prefix(maxChars - 1)) + "…"
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// Affine transform that maps rect `a` onto rect `b`.
    private func transform(from a: CGRect, to b: CGRect) -> CGAffineTransform {
        guard a.width > 0, a.height > 0 else { return .identity }
        let sx = b.width / a.width
        let sy = b.height / a.height
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: b.minX - a.minX * sx, ty: b.minY - a.minY * sy)
    }
}

/// Spring curves, as functions of elapsed seconds, normalised to finish at 1.
enum Spring {
    /// Slightly underdamped: overshoots by a few percent, then settles. Used when tiles grow.
    static func bouncy(_ t: TimeInterval) -> Double {
        let zeta = 0.68, omega = 15.0
        let wd = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        return 1 - decay * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
    }

    /// Critically damped: fast start, no overshoot, glides to a stop. Used when zooming.
    static func settle(_ t: TimeInterval, duration: TimeInterval) -> Double {
        let omega = 26.0
        let raw = { (x: Double) in 1 - exp(-omega * x) * (1 + omega * x) }
        return min(1, raw(t) / raw(duration))
    }
}
