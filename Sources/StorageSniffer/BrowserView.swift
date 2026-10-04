import SwiftUI
import SnifferCore

/// Treemap and ranked list for the current folder, with breadcrumbs and scan status.
struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // Sizes are atomics in the tree; reading `revision` re-renders on each refresh.
        let _ = model.revision
        VStack(spacing: 0) {
            PathBar()
            if !model.hasFullDiskAccess && model.progress.denied > 0 {
                AccessBanner()
            }
            HSplitView {
                TreemapView()
                    .padding(8)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                ItemListView()
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 520, maxHeight: .infinity)
            }
            Divider()
            StatusBar()
        }
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.goUp() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoUp)
                    .help("Go to the enclosing folder (⌘↑)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.rescanAll() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy)
                    .help("Scan again from the top (⌘R)")
                Button { model.backToStart() } label: { Label("New Scan", systemImage: "square.grid.2x2") }
                    .help("Choose something else to scan")
            }
        }
        .navigationTitle(model.current.map(model.displayName(of:)) ?? "Storage Sniffer")
        .navigationSubtitle(subtitle)
        .confirmationDialog(trashTitle, isPresented: trashPresented, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
        } message: {
            Text("The space is freed when you empty the Trash. You can undo with ⌘Z or Put Back in Finder.")
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var subtitle: String {
        guard let current = model.current else { return "" }
        if current === model.root, model.isWholeDisk, let volume = model.volume {
            return "\(Format.bytes(volume.used)) used of \(Format.bytes(volume.total))"
        }
        return Format.bytes(current.totalSize)
    }

    private var trashTitle: String {
        guard let item = model.pendingTrash else { return "" }
        return "Move “\(item.name)” (\(Format.bytes(item.size))) to the Trash?"
    }

    private var trashPresented: Binding<Bool> {
        Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Clickable breadcrumbs plus live scan progress.
private struct PathBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let lineage = model.current?.lineage ?? []
                    ForEach(Array(lineage.enumerated()), id: \.element.id) { index, dir in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            model.open(dir)
                        } label: {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: model.isWholeDisk ? "internaldrive" : "house")
                                }
                                Text(model.displayName(of: dir))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(dir === model.current ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                        in: .rect(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .fontWeight(dir === model.current ? .semibold : .regular)
                    }
                }
                .font(.callout)
            }
            .defaultScrollAnchor(.leading, for: .alignment)
            .defaultScrollAnchor(.trailing, for: .initialOffset)
            .defaultScrollAnchor(.trailing, for: .sizeChanges)
            .frame(maxWidth: .infinity, alignment: .leading)
            ScanStatus()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

private struct ScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.progress
        HStack(spacing: 8) {
            if model.phase == .scanning {
                if let fraction = estimatedFraction {
                    ProgressView(value: fraction).frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("\(Format.count(p.files)) files · \(Format.bytes(p.bytes))")
                    .monospacedDigit()
                Button("Stop") { model.cancelScan(); model.backToStart() }
                    .controlSize(.small)
            } else if model.rescanning != nil {
                ProgressView().controlSize(.small)
                Text("Rescanning…")
            } else if model.phase == .done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(Format.count(p.files)) files in \(String(format: "%.1f", model.scanDuration))s")
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// For whole-disk scans the used space gives a good progress estimate.
    private var estimatedFraction: Double? {
        guard model.isWholeDisk, let used = model.volume?.used, used > 0 else { return nil }
        return min(0.99, Double(model.progress.bytes) / Double(used))
    }
}

private struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .foregroundStyle(.orange)
            Text("\(Format.count(model.progress.denied)) folders couldn’t be read, so totals are lower than reality.")
            Spacer()
            Button("Grant Full Disk Access…") { FullDiskAccess.openSettings() }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.12))
    }
}

/// Details of the hovered (or selected) item.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        HStack(spacing: 8) {
            if let item = model.hovered ?? model.item(for: model.selection) {
                Image(systemName: item.symbol).foregroundStyle(.secondary)
                Text(description(of: item))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(details(of: item))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if let current = model.current {
                Text("Click a folder to zoom in. Right-click for more actions.")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.bytes(model.displayedSize(of: current))) · \(Format.count(current.totalFiles)) files")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func description(of item: Item) -> String {
        switch item.kind {
        case .hidden(.free):
            "Free space: available for new files"
        case .hidden(.purgeable):
            "Purgeable: caches and snapshots macOS frees automatically when space runs low"
        case .hidden(.other):
            model.trashIsUnreadable
                ? "Includes your Trash, which macOS hides without Full Disk Access. Empty the Trash to free it."
                : "Used space the scan can’t see: APFS snapshots, protected system data, unreadable folders"
        case .smaller:
            item.name
        default:
            item.path ?? item.name
        }
    }

    private func details(of item: Item) -> String {
        var parts = [Format.bytes(item.size)]
        if let total = model.current.map(model.displayedSize(of:)), total > 0 {
            parts.append(Format.percent(item.size, of: total))
        }
        if item.isFolder, let n = item.fileCount {
            parts.append("\(Format.count(n)) files")
        }
        if case .file(let f) = item.kind, f.flags.contains(.duplicateHardLink) {
            parts.append("hard link, counted elsewhere")
        }
        if case .folder(let d) = item.kind, d.state == .denied {
            parts.append("no access")
        }
        if case .file(let f) = item.kind, f.flags.contains(.sharesClonedBlocks) {
            parts.append("APFS clone, shared blocks counted once")
        }
        return parts.joined(separator: " · ")
    }
}
