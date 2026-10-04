import SwiftUI
import SnifferCore

/// Ranked list of the current folder's contents, largest first.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    /// Rows past this are folded into one "smaller items" row to keep the list snappy.
    private let maxRows = 400

    var body: some View {
        @Bindable var model = model
        let rows = self.rows
        let total = model.current.map(model.displayedSize(of:)) ?? 0

        List(selection: $model.selection) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                ItemRow(item: item, total: total,
                        color: Palette.color(for: item, hue: Palette.hue(at: index), depth: 1,
                                             index: index, dark: colorScheme == .dark))
                    .tag(item.id)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: model.layoutRevision)
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Item.ID.self) { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                ItemMenu(item: item)
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id }), let folder = item.folder {
                model.open(folder)
            }
        }
        .onKeyPress(.return) {
            guard let item = model.item(for: model.selection), let folder = item.folder else { return .ignored }
            model.open(folder)
            return .handled
        }
    }

    private var rows: [Item] {
        guard let current = model.current else { return [] }
        _ = model.revision
        let items = model.items(of: current)
        guard items.count > maxRows else { return items }
        let rest = items[maxRows...]
        let restSize = rest.reduce(Int64(0)) { $0 + $1.size }
        return Array(items[..<maxRows]) + [Item(kind: .smaller(count: rest.count),
                                                 name: "\(rest.count.formatted()) smaller items",
                                                 size: restSize, parent: current)]
    }
}

private struct ItemRow: View {
    let item: Item
    let total: Int64
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isScanning {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 8)
                    Text(Format.bytes(item.size))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(item.size)))
                        .foregroundStyle(.secondary)
                }
                ShareBar(fraction: total > 0 ? Double(item.size) / Double(total) : 0, color: color)
            }
            Text(Format.percent(item.size, of: total))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .help(item.path ?? item.name)
    }
}

private struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                Capsule().fill(color.gradient)
                    .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * fraction))
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: fraction)
        }
        .frame(height: 4)
    }
}

/// Actions for an item, shared by the treemap and the list.
struct ItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        if let folder = item.folder {
            Button("Open") { model.open(folder) }
        }
        if item.isReal {
            Button("Reveal in Finder") { model.reveal(item) }
            Button("Copy Path") { model.copyPath(item) }
        }
        if let folder = item.folder {
            Button("Rescan Folder") { model.rescan(folder) }
                .disabled(model.isBusy)
        }
        if item.isReal {
            Divider()
            Button("Move to Trash…", role: .destructive) { model.requestTrash(item) }
                .disabled(model.isBusy)
        }
        if case .hidden(let unseen) = item.kind {
            Text(unseen == .purgeable
                 ? "macOS frees this automatically when space runs low"
                 : "APFS snapshots, protected system data and unreadable folders")
        }
    }
}
