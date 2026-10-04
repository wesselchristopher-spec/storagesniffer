import Foundation
import Synchronization

/// A file inside a scanned directory. Files are stored as compact values rather than
/// objects so that trees with millions of files stay small.
public struct FileEntry: Sendable, Hashable {
    public let name: String
    /// Bytes allocated on disk (not the logical length). Zero for hard links whose
    /// storage is already counted elsewhere, and for cloud-only (dataless) files.
    public let size: Int64
    public let flags: Flags

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// Another path to the same storage was counted instead of this one.
        public static let duplicateHardLink = Flags(rawValue: 1 << 0)
        public static let symlink = Flags(rawValue: 1 << 1)
        /// An APFS clone whose shared blocks were counted with another member of its family.
        public static let sharesClonedBlocks = Flags(rawValue: 1 << 2)
    }

    public init(name: String, size: Int64, flags: Flags = []) {
        self.name = name
        self.size = size
        self.flags = flags
    }
}

/// A directory in the scanned tree.
///
/// Thread-safety: `size`, `fileCount` and `state` are atomics and may be read at any time,
/// including while the scan runs. `dirs` and `files` are written exactly once by the worker
/// that lists the directory, before `state` is published with release ordering, so readers
/// must check `isListed` before touching them. After a scan finishes, mutations (trash,
/// rescan) happen on the main thread only.
public final class DirNode: @unchecked Sendable, Identifiable {
    public enum State: UInt8, Sendable {
        case pending = 0
        /// Children are listed; descendants may still be scanning.
        case listed = 1
        /// The directory could not be read (usually missing Full Disk Access).
        case denied = 2
        case error = 3
        /// A grafted disk image whose bytes are counted as the image file elsewhere.
        case graft = 4
    }

    public let name: String
    public private(set) weak var parent: DirNode?
    /// Absolute path, set on the node a scan started from. Other nodes derive their path.
    public let basePath: String?

    public var dirs: [DirNode] = []
    public var files: [FileEntry] = []

    /// Allocated bytes of everything beneath this directory. Grows while scanning.
    public let size = Atomic<Int64>(0)
    /// Number of files beneath this directory.
    public let fileCount = Atomic<Int64>(0)
    /// Directories beneath this one (including itself) that are not finished yet.
    let remaining = Atomic<Int32>(1)
    private let rawState = Atomic<UInt8>(State.pending.rawValue)

    public init(name: String, parent: DirNode?, basePath: String? = nil) {
        self.name = name
        self.parent = parent
        self.basePath = basePath
    }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    public var state: State { State(rawValue: rawState.load(ordering: .acquiring)) ?? .error }
    public var isListed: Bool { state == .listed }
    /// True when this directory and everything beneath it has been scanned.
    public var isComplete: Bool { remaining.load(ordering: .acquiring) <= 0 }
    public var totalSize: Int64 { size.load(ordering: .relaxed) }
    public var totalFiles: Int64 { fileCount.load(ordering: .relaxed) }

    func publish(_ state: State) {
        rawState.store(state.rawValue, ordering: .releasing)
    }

    public var path: String {
        if let basePath { return basePath }
        var parts: [String] = [name]
        var node = parent
        while let n = node {
            if let base = n.basePath {
                return (base == "/" ? "" : base) + "/" + parts.reversed().joined(separator: "/")
            }
            parts.append(n.name)
            node = n.parent
        }
        return "/" + parts.reversed().joined(separator: "/")
    }

    public func path(ofFile name: String) -> String {
        let p = path
        return p == "/" ? "/" + name : p + "/" + name
    }

    /// Ancestors from the root down to (and including) this node.
    public var lineage: [DirNode] {
        var out: [DirNode] = []
        var node: DirNode? = self
        while let n = node {
            out.append(n)
            node = n.parent
        }
        return out.reversed()
    }

    public func isDescendant(of other: DirNode) -> Bool {
        var node: DirNode? = self
        while let n = node {
            if n === other { return true }
            node = n.parent
        }
        return false
    }

    /// Adds to this directory and every ancestor.
    func addToLineage(bytes: Int64, files: Int64, stopAt top: DirNode?) {
        var node: DirNode? = self
        while let n = node {
            if bytes != 0 { n.size.add(bytes, ordering: .relaxed) }
            if files != 0 { n.fileCount.add(files, ordering: .relaxed) }
            if n === top { break }
            node = n.parent
        }
    }

    // MARK: Main-thread mutations, valid only while no scan is running.

    /// Removes a subdirectory after it was moved to the Trash and updates ancestor totals.
    public func removeDir(_ child: DirNode) {
        guard let i = dirs.firstIndex(where: { $0 === child }) else { return }
        dirs.remove(at: i)
        addToLineage(bytes: -child.totalSize, files: -child.totalFiles, stopAt: nil)
    }

    /// Removes a file after it was moved to the Trash and updates ancestor totals.
    public func removeFile(named name: String) {
        guard let i = files.firstIndex(where: { $0.name == name }) else { return }
        let f = files.remove(at: i)
        addToLineage(bytes: -f.size, files: -1, stopAt: nil)
    }

    /// Swaps in a freshly rescanned copy of a subdirectory.
    public func replaceDir(_ old: DirNode, with new: DirNode) {
        guard let i = dirs.firstIndex(where: { $0 === old }) else { return }
        dirs[i] = new
        addToLineage(bytes: new.totalSize - old.totalSize,
                     files: new.totalFiles - old.totalFiles, stopAt: nil)
    }
}
