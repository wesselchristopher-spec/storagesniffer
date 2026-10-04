import Darwin
import Foundation
import Synchronization

/// Live counters for a running scan. Safe to read from any thread.
public final class ScanProgress: Sendable {
    public let files = Atomic<Int64>(0)
    public let dirs = Atomic<Int64>(0)
    public let bytes = Atomic<Int64>(0)
    public let denied = Atomic<Int64>(0)

    public struct Snapshot: Sendable {
        public var files: Int64
        public var dirs: Int64
        public var bytes: Int64
        public var denied: Int64

        public init(files: Int64, dirs: Int64, bytes: Int64, denied: Int64) {
            self.files = files
            self.dirs = dirs
            self.bytes = bytes
            self.denied = denied
        }
    }

    public var snapshot: Snapshot {
        Snapshot(files: files.load(ordering: .relaxed), dirs: dirs.load(ordering: .relaxed),
                 bytes: bytes.load(ordering: .relaxed), denied: denied.load(ordering: .relaxed))
    }
}

/// Scans a directory tree in parallel and builds a `DirNode` tree whose sizes are the bytes
/// actually allocated on disk.
///
/// Accuracy rules:
/// - Sizes are allocated bytes (like `du`), so sparse, compressed and cloud-only files count
///   for what they really occupy.
/// - Hard-linked files are counted once, and blocks shared between APFS clones are counted
///   once per clone family (other members count only their private bytes).
/// - The scan stays inside the APFS container of the starting folder: other disks, network
///   shares and disk images are skipped, but sibling volumes of the same disk (Data, VM,
///   Preboot) are included because they share its space.
/// - Grafted disk images (the OS cryptexes) are skipped; their image files are counted instead.
/// - When scanning `/`, firmlinked folders inside `/System/Volumes/Data` are skipped, since
///   they are the same folders as `/Users`, `/Applications`, etc.
public final class DiskScanner: @unchecked Sendable {
    public let root: DirNode
    public let rootPath: String
    public let progress = ScanProgress()

    private let excludedPaths: Set<String>
    private let rootContainer: String?
    private let rootFSID: fsid_t?
    private let workerCount: Int

    private struct Work {
        let node: DirNode
        let path: String
    }

    private let lock = NSCondition()
    private var stack: [Work] = []
    private var outstanding = 0
    private let cancelled = Atomic<Bool>(false)
    private let hardLinks = Mutex<Set<FileKey>>([])
    private let cloneFamilies = Mutex<Set<FileKey>>([])

    private struct FileKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    /// - Parameters:
    ///   - path: Absolute path of the folder to scan.
    ///   - parent: When rescanning a subfolder, the parent node the new tree attaches to.
    ///     Totals are not propagated to it; the caller swaps the result in when done.
    public init(path: String, parent: DirNode? = nil) {
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        rootPath = normalized
        let name = parent == nil
            ? normalized
            : (normalized as NSString).lastPathComponent
        root = DirNode(name: name, parent: parent, basePath: parent == nil ? normalized : nil)
        workerCount = max(2, ProcessInfo.processInfo.activeProcessorCount)

        let fs = DiskScanner.fsInfo(normalized)
        rootContainer = fs.flatMap { DiskScanner.container(of: $0) }
        rootFSID = fs?.f_fsid

        excludedPaths = normalized == "/" ? DiskScanner.firmlinkTargets() : []
    }

    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
        lock.lock()
        lock.broadcast()
        lock.unlock()
    }

    /// Scans on background threads and calls `completion` on an arbitrary thread when done.
    public func start(completion: @escaping @Sendable (DiskScanner) -> Void) {
        DiskScanner.disableDatalessMaterialization()
        lock.lock()
        stack.append(Work(node: root, path: rootPath))
        outstanding = 1
        lock.unlock()

        let group = DispatchGroup()
        for i in 0..<workerCount {
            group.enter()
            let thread = Thread { [self] in
                worker()
                group.leave()
            }
            thread.name = "scan-\(i)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.notify(queue: .global(qos: .userInitiated)) { [self] in
            completion(self)
        }
    }

    /// Scans and blocks until finished.
    public func run() {
        let done = DispatchSemaphore(value: 0)
        start { _ in done.signal() }
        done.wait()
    }

    // MARK: Workers

    private func worker() {
        let reader = BulkReader()
        var newWork: [Work] = []
        while true {
            lock.lock()
            while stack.isEmpty && outstanding > 0 && !isCancelled {
                lock.wait()
            }
            if isCancelled || (stack.isEmpty && outstanding == 0) {
                lock.broadcast()
                lock.unlock()
                return
            }
            let work = stack.removeLast()
            lock.unlock()

            newWork.removeAll(keepingCapacity: true)
            scan(work, reader: reader, into: &newWork)

            lock.lock()
            outstanding += newWork.count - 1
            stack.append(contentsOf: newWork)
            if newWork.count > 1 || outstanding == 0 {
                lock.broadcast()
            } else if newWork.count == 1 {
                lock.signal()
            }
            lock.unlock()
        }
    }

    private func scan(_ work: Work, reader: BulkReader, into newWork: inout [Work]) {
        let node = work.node
        let base = work.path == "/" ? "" : work.path

        var dirs: [DirNode] = []
        var files: [FileEntry] = []
        var bytes: Int64 = 0
        var mountPoints: [String] = []

        let result = reader.read(path: work.path, isRoot: node === root) { entry in
            switch entry.kind {
            case .directory:
                let childPath = base + "/" + entry.name
                if !excludedPaths.isEmpty && excludedPaths.contains(childPath) { return }
                if entry.isMountPoint {
                    mountPoints.append(entry.name)
                    return
                }
                dirs.append(DirNode(name: entry.name, parent: node))
            case .file, .symlink, .other:
                var size = entry.allocatedSize
                var flags: FileEntry.Flags = entry.kind == .symlink ? .symlink : []
                if entry.linkCount > 1 {
                    let key = FileKey(dev: entry.device, ino: entry.fileID)
                    let isNew = hardLinks.withLock { $0.insert(key).inserted }
                    if !isNew {
                        size = 0
                        flags.insert(.duplicateHardLink)
                    }
                }
                // APFS clones share blocks. Count a file's private bytes always, and the
                // shared part only for the first member of each clone family we meet.
                if size > 0, entry.mayShareBlocks, let clone = reader.cloneInfo(name: entry.name),
                   clone.privateSize < size {
                    let priv = clone.privateSize
                    let key = FileKey(dev: entry.device, ino: clone.cloneID)
                    let isNew = cloneFamilies.withLock { $0.insert(key).inserted }
                    if !isNew {
                        size = priv
                        flags.insert(.sharesClonedBlocks)
                    }
                }
                bytes += size
                files.append(FileEntry(name: entry.name, size: size, flags: flags))
            }
        }

        // Only descend into mount points that live on the same disk as the scan root.
        for name in mountPoints {
            let childPath = base + "/" + name
            if isSameDisk(childPath) {
                dirs.append(DirNode(name: name, parent: node))
            }
        }

        switch result {
        case .ok:
            break
        case .graft:
            node.publish(.graft)
            finish(node)
            return
        case .denied:
            progress.denied.add(1, ordering: .relaxed)
            node.publish(.denied)
            finish(node)
            return
        case .error:
            node.publish(.error)
            finish(node)
            return
        }

        node.dirs = dirs
        node.files = files
        node.remaining.add(Int32(dirs.count), ordering: .relaxed)
        node.publish(.listed)

        node.addToLineage(bytes: bytes, files: Int64(files.count), stopAt: root)
        progress.files.add(Int64(files.count), ordering: .relaxed)
        progress.dirs.add(1, ordering: .relaxed)
        progress.bytes.add(bytes, ordering: .relaxed)

        for d in dirs {
            newWork.append(Work(node: d, path: base + "/" + d.name))
        }
        finish(node)
    }

    /// Marks one unit of a directory's subtree as done and bubbles completion upward.
    private func finish(_ node: DirNode) {
        var n: DirNode? = node
        while let current = n {
            let left = current.remaining.subtract(1, ordering: .acquiringAndReleasing).newValue
            if left > 0 || current === root { return }
            n = current.parent
        }
    }

    private func isSameDisk(_ path: String) -> Bool {
        guard let fs = DiskScanner.fsInfo(path) else { return false }
        if let rootContainer, let c = DiskScanner.container(of: fs) {
            return c == rootContainer
        }
        if let rootFSID {
            return fs.f_fsid.val.0 == rootFSID.val.0 && fs.f_fsid.val.1 == rootFSID.val.1
        }
        return false
    }

    // MARK: System helpers

    static func fsInfo(_ path: String) -> Darwin.statfs? {
        var s = Darwin.statfs()
        let ok = path.withCString { cPath in
            withUnsafeMutablePointer(to: &s) { callStatfs(cPath, $0) }
        }
        return ok ? s : nil
    }

    /// The whole-disk identifier ("disk3") a volume lives on, from its mount source
    /// such as "/dev/disk3s1s1".
    static func container(of fs: Darwin.statfs) -> String? {
        let from = withUnsafeBytes(of: fs.f_mntfromname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        guard let r = from.range(of: "/dev/disk") else { return nil }
        let digits = from[r.upperBound...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : "disk" + digits
    }

    /// Paths under /System/Volumes/Data that are firmlinked into the root of the disk.
    static func firmlinkTargets() -> Set<String> {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)
        else {
            return ["/System/Volumes/Data/Users", "/System/Volumes/Data/Applications",
                    "/System/Volumes/Data/Library", "/System/Volumes/Data/private",
                    "/System/Volumes/Data/Volumes", "/System/Volumes/Data/opt",
                    "/System/Volumes/Data/cores", "/System/Volumes/Data/usr/local"]
        }
        var out: Set<String> = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count == 2 {
                out.insert("/System/Volumes/Data/" + parts[1])
            }
        }
        return out
    }

    /// Keeps the scan from downloading iCloud-evicted files or folders.
    static func disableDatalessMaterialization() {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }
}

private func callStatfs(_ path: UnsafePointer<CChar>, _ buf: UnsafeMutablePointer<Darwin.statfs>) -> Bool {
    statfs(path, buf) == 0
}
