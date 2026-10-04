import AppKit
import Observation
import SnifferCore

@Observable
@MainActor
final class AppModel {
    enum Phase {
        case start, scanning, done
    }

    private(set) var phase: Phase = .start
    private(set) var root: DirNode?
    private(set) var rootPath = ""
    private(set) var volume: VolumeInfo?
    private(set) var progress = ScanProgress.Snapshot(files: 0, dirs: 0, bytes: 0, denied: 0)
    private(set) var scanStarted = Date()
    private(set) var scanDuration: TimeInterval = 0
    /// Bumped whenever sizes or contents change so views re-read the tree.
    private(set) var revision = 0
    /// Bumped less often while scanning, so the treemap doesn't reshuffle under the cursor.
    private(set) var layoutRevision = 0
    private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess

    /// Your Trash, pulled out of the home folder and shown as its own item at the root.
    /// Nil until the scan finishes, or when macOS won't let us read it.
    private(set) var trash: DirNode?

    /// The folder being viewed.
    private(set) var current: DirNode?
    var selection: Item.ID?
    var hovered: Item?
    var pendingTrash: Item?
    var errorMessage: String?
    private(set) var rescanning: DirNode?
    private(set) var lastTrashed: (original: URL, inTrash: URL, parent: DirNode)?

    private var scanner: DiskScanner?
    private var ticker: Task<Void, Never>?
    private var sortedCache: [ObjectIdentifier: [Item]] = [:]

    var isBusy: Bool { phase == .scanning || rescanning != nil }
    var isWholeDisk: Bool { rootPath == "/" }

    var rootDisplayName: String {
        if isWholeDisk { return volume?.name ?? "Macintosh HD" }
        if rootPath == NSHomeDirectory() { return NSUserName() }
        return (rootPath as NSString).lastPathComponent
    }

    func displayName(of dir: DirNode) -> String {
        if dir === trash { return "Trash" }
        return dir === root ? rootDisplayName : dir.name
    }

    // MARK: Scanning

    func startScan(path: String) {
        cancelScan()
        refreshPermissions()
        let scanner = DiskScanner(path: path)
        self.scanner = scanner
        rootPath = scanner.rootPath
        root = scanner.root
        current = scanner.root
        volume = VolumeInfo(path: path)
        selection = nil
        hovered = nil
        lastTrashed = nil
        trash = nil
        sortedCache = [:]
        phase = .scanning
        scanStarted = Date()

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.tick()
            }
        }
        scanner.start { [weak self] finished in
            Task { @MainActor in self?.scanFinished(finished) }
        }
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        ticker?.cancel()
        ticker = nil
    }

    func backToStart() {
        cancelScan()
        phase = .start
        root = nil
        current = nil
        sortedCache = [:]
    }

    func rescanAll() {
        guard !rootPath.isEmpty else { return }
        startScan(path: rootPath)
    }

    private func tick() {
        guard let scanner else { return }
        progress = scanner.progress.snapshot
        scanDuration = Date().timeIntervalSince(scanStarted)
        revision += 1
        if revision % 3 == 0 { layoutRevision += 1 }
    }

    private func scanFinished(_ finished: DiskScanner) {
        guard finished === scanner, !finished.isCancelled else { return }
        tick()
        ticker?.cancel()
        ticker = nil
        volume = VolumeInfo(path: rootPath)
        phase = .done
        separateTrash()
        revision += 1
        layoutRevision += 1
    }

    /// Moves ~/.Trash out of the home folder into its own root-level item, so what's
    /// waiting to be emptied isn't mixed in with your files.
    private func separateTrash() {
        guard let root else { return }
        let trashPath = NSHomeDirectory() + "/.Trash"
        let base = rootPath == "/" ? "" : rootPath
        guard trashPath.hasPrefix(base + "/") else { return }
        var node: DirNode? = root
        for name in trashPath.dropFirst(base.count + 1).split(separator: "/") {
            node = node.flatMap { n in n.isListed ? n.dirs.first { $0.name == name } : nil }
        }
        guard let found = node, found.isListed, let parent = found.parent else { return }
        parent.removeDir(found)
        trash = found
        sortedCache = [:]
    }

    /// Rescans one folder in place, e.g. after cleaning it up in Finder.
    func rescan(_ dir: DirNode) {
        guard phase == .done, rescanning == nil else { return }
        guard let parent = dir.parent else { return rescanAll() }
        rescanning = dir
        let scanner = DiskScanner(path: dir.path, parent: parent)
        scanner.start { [weak self] finished in
            Task { @MainActor in self?.rescanFinished(old: dir, new: finished.root) }
        }
    }

    private func rescanFinished(old: DirNode, new: DirNode) {
        rescanning = nil
        guard let parent = old.parent else { return }
        parent.replaceDir(old, with: new)
        if let current, current.isDescendant(of: old) { self.current = new }
        if selection == .folder(old.id) { selection = .folder(new.id) }
        // Rescanning a folder that contains the Trash brings a fresh copy of it back.
        if let trash, trash.path.hasPrefix(new.path + "/") {
            self.trash = nil
            if let current, current.isDescendant(of: trash) { self.current = root }
            separateTrash()
        }
        contentsChanged()
    }

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess
    }

    // MARK: Navigation

    func open(_ dir: DirNode) {
        guard dir !== current else { return }
        current = dir
        hovered = nil
    }

    func open(_ item: Item) {
        if let folder = item.folder {
            open(folder)
        } else {
            open(item.parent)
            selection = item.id
        }
    }

    func goUp() {
        guard let current, current !== root else { return }
        if current === trash, let root {
            open(root)
            selection = .folder(current.id)
            return
        }
        guard let parent = current.parent else { return }
        let child = current
        open(parent)
        selection = .folder(child.id)
    }

    var canGoUp: Bool { current != nil && current !== root }

    // MARK: Contents

    /// Children of a folder, largest first, plus the hidden-space item at the disk root.
    func items(of dir: DirNode) -> [Item] {
        var items: [Item]
        if dir.isComplete, let cached = sortedCache[dir.id] {
            items = cached
        } else {
            items = Item.children(of: dir)
            if dir.isComplete { sortedCache[dir.id] = items }
        }
        if dir === root, let trash, trash.totalSize > 0 {
            let item = Item(kind: .folder(trash), name: "Trash", size: trash.totalSize, parent: dir)
            let i = items.firstIndex { $0.size < item.size } ?? items.count
            items.insert(item, at: i)
        }
        if dir === root {
            for (kind, size) in diskExtras {
                let name = switch kind {
                case .free: "Free space"
                case .purgeable: "Purgeable space"
                case .other: trashIsUnreadable ? "Hidden data & Trash" : "Hidden & system data"
                }
                let item = Item(kind: .hidden(kind), name: name, size: size, parent: dir)
                let i = items.firstIndex { $0.size < size } ?? items.count
                items.insert(item, at: i)
            }
        }
        return items
    }

    /// Extra items at the root of a whole-disk scan so it adds up to the disk's capacity:
    /// free space, plus used space the scan could not see (once the scan has finished), split
    /// into what macOS reports as purgeable and the rest.
    var diskExtras: [(Item.Unseen, Int64)] {
        guard isWholeDisk, let volume, let root else { return [] }
        let minimum = volume.total / 1000
        var out: [(Item.Unseen, Int64)] = []
        if volume.free > 0 { out.append((.free, volume.free)) }
        guard phase == .done else { return out }
        let gap = volume.used - root.totalSize
        guard gap > minimum else { return out }
        let purgeable = min(volume.purgeable, gap)
        if purgeable > minimum { out.append((.purgeable, purgeable)) }
        if gap - purgeable > minimum { out.append((.other, gap - purgeable)) }
        return out
    }

    /// The Trash is protected by macOS; without Full Disk Access its contents land in
    /// "Hidden & system data" and can be most of it right after a big cleanup.
    var trashIsUnreadable: Bool {
        let fd = Darwin.open(NSHomeDirectory() + "/.Trash", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { close(fd); return false }
        return errno == EPERM || errno == EACCES
    }

    /// Size shown for a folder. At the disk root this is the whole disk, including free space
    /// and space the scan couldn't see, so percentages are shares of the disk.
    func displayedSize(of dir: DirNode) -> Int64 {
        guard dir === root else { return dir.totalSize }
        return dir.totalSize + (trash?.totalSize ?? 0) + diskExtras.reduce(0) { $0 + $1.1 }
    }

    func item(for id: Item.ID?) -> Item? {
        guard let id, let current else { return nil }
        return items(of: current).first { $0.id == id }
    }

    private func contentsChanged() {
        sortedCache = [:]
        revision += 1
        layoutRevision += 1
    }

    // MARK: Actions

    func reveal(_ item: Item) {
        guard let path = item.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyPath(_ item: Item) {
        guard let path = item.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// True for the Trash and anything inside it, which can't be moved to the Trash again.
    func isInTrash(_ item: Item) -> Bool {
        guard let trash else { return false }
        if let folder = item.folder { return folder.isDescendant(of: trash) }
        return item.parent.isDescendant(of: trash)
    }

    func requestTrash(_ item: Item) {
        guard item.isReal, !isInTrash(item) else { return }
        if isBusy {
            errorMessage = "Wait for the scan to finish before moving items to the Trash."
            return
        }
        if let folder = item.folder, current?.isDescendant(of: folder) ?? true {
            errorMessage = "You can’t move the folder you’re viewing to the Trash. Go up a level first."
            return
        }
        pendingTrash = item
    }

    func confirmTrash() {
        guard let item = pendingTrash, let path = item.path else { return }
        pendingTrash = nil
        let url = URL(fileURLWithPath: path)
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            switch item.kind {
            case .folder(let d): item.parent.removeDir(d)
            case .file(let f): item.parent.removeFile(named: f.name)
            default: break
            }
            if let resulting = resulting as URL? {
                lastTrashed = (url, resulting, item.parent)
            }
            if selection == item.id { selection = nil }
            if hovered?.id == item.id { hovered = nil }
            contentsChanged()
        } catch {
            errorMessage = "Couldn’t move “\(item.name)” to the Trash. \(error.localizedDescription)"
        }
    }

    var canUndoTrash: Bool { lastTrashed != nil && !isBusy }

    /// Puts the last trashed item back and rescans where it landed.
    func undoTrash() {
        guard let last = lastTrashed, !isBusy else { return }
        lastTrashed = nil
        do {
            try FileManager.default.moveItem(at: last.inTrash, to: last.original)
        } catch {
            errorMessage = "Couldn’t put the item back. \(error.localizedDescription)"
            return
        }
        // Rescan the folder it came from so it reappears with an accurate size.
        if last.parent === root { rescanAll() } else { rescan(last.parent) }
    }
}
