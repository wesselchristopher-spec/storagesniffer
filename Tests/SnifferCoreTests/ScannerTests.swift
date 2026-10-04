import Darwin
import Foundation
import Testing
@testable import SnifferCore

/// Builds a throwaway directory tree and returns its path.
private func makeTree(_ build: (String) throws -> Void) throws -> String {
    let dir = NSTemporaryDirectory() + "sniff-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try build(dir)
    return dir
}

private func write(_ path: String, bytes: Int) throws {
    try Data(repeating: 0xA5, count: bytes).write(to: URL(fileURLWithPath: path))
}

/// Allocated bytes as reported by stat, i.e. what `du` counts.
private func allocated(_ path: String) -> Int64 {
    var st = stat()
    lstat(path, &st)
    return Int64(st.st_blocks) * 512
}

@Suite struct ScannerTests {
    @Test func totalsMatchAllocatedBytes() throws {
        var paths: [String] = []
        let root = try makeTree { dir in
            try FileManager.default.createDirectory(atPath: dir + "/a/b/c", withIntermediateDirectories: true)
            for (i, p) in ["/one", "/a/two", "/a/b/three", "/a/b/c/four"].enumerated() {
                try write(dir + p, bytes: 10_000 * (i + 1) + 123)
                paths.append(dir + p)
            }
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let scanner = DiskScanner(path: root)
        scanner.run()

        let expected = paths.reduce(Int64(0)) { $0 + allocated($1) }
        #expect(scanner.root.totalSize == expected)
        #expect(scanner.root.totalFiles == 4)
        #expect(scanner.root.isComplete)
        let a = try #require(scanner.root.dirs.first { $0.name == "a" })
        #expect(a.totalFiles == 3)
        #expect(a.isComplete)
        let b = try #require(a.dirs.first)
        #expect(b.path == root + "/a/b")
    }

    @Test func sparseFilesCountAllocatedNotLogicalSize() throws {
        let root = try makeTree { dir in
            let fd = open(dir + "/sparse", O_CREAT | O_WRONLY, 0o644)
            ftruncate(fd, 1 << 30) // 1 GiB logical, almost nothing allocated
            close(fd)
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let scanner = DiskScanner(path: root)
        scanner.run()
        #expect(scanner.root.totalSize < 1 << 20)
        #expect(scanner.root.totalSize == allocated(root + "/sparse"))
    }

    @Test func hardLinksAreCountedOnce() throws {
        let root = try makeTree { dir in
            try FileManager.default.createDirectory(atPath: dir + "/x", withIntermediateDirectories: true)
            try write(dir + "/original", bytes: 200_000)
            link(dir + "/original", dir + "/x/link")
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let scanner = DiskScanner(path: root)
        scanner.run()
        #expect(scanner.root.totalSize == allocated(root + "/original"))
        let all = scanner.root.files + scanner.root.dirs.flatMap(\.files)
        #expect(all.filter { $0.flags.contains(.duplicateHardLink) }.count == 1)
    }

    @Test func apfsClonesShareTheirBlocksOnce() throws {
        let root = try makeTree { dir in
            try FileManager.default.createDirectory(atPath: dir + "/copies", withIntermediateDirectories: true)
            try write(dir + "/original", bytes: 4_000_000)
            #expect(clonefile(dir + "/original", dir + "/copies/clone", 0) == 0)
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let scanner = DiskScanner(path: root)
        scanner.run()
        // du would report both files in full; the clone adds no new blocks.
        #expect(scanner.root.totalSize == allocated(root + "/original"))
        let all = scanner.root.files + scanner.root.dirs.flatMap(\.files)
        #expect(all.filter { $0.flags.contains(.sharesClonedBlocks) }.count == 1)
    }

    @Test func symlinksAreNotFollowed() throws {
        let root = try makeTree { dir in
            try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
            try write(dir + "/real/big", bytes: 500_000)
            symlink(dir + "/real", dir + "/alias")
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let scanner = DiskScanner(path: root)
        scanner.run()
        #expect(scanner.root.dirs.count == 1)
        let alias = try #require(scanner.root.files.first { $0.name == "alias" })
        #expect(alias.flags.contains(.symlink))
        #expect(scanner.root.totalSize < 600_000)
    }

    @Test func unreadableFoldersAreReported() throws {
        let root = try makeTree { dir in
            try FileManager.default.createDirectory(atPath: dir + "/locked", withIntermediateDirectories: true)
            try write(dir + "/locked/secret", bytes: 1000)
            chmod(dir + "/locked", 0)
        }
        defer {
            chmod(root + "/locked", 0o755)
            try? FileManager.default.removeItem(atPath: root)
        }

        let scanner = DiskScanner(path: root)
        scanner.run()
        #expect(scanner.progress.snapshot.denied == 1)
        #expect(scanner.root.dirs.first?.state == .denied)
        #expect(scanner.root.isComplete)
    }

    @Test func removeAndReplaceUpdateAncestors() throws {
        let root = try makeTree { dir in
            try FileManager.default.createDirectory(atPath: dir + "/a/b", withIntermediateDirectories: true)
            try write(dir + "/a/b/f1", bytes: 100_000)
            try write(dir + "/a/f2", bytes: 50_000)
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let scanner = DiskScanner(path: root)
        scanner.run()
        let a = try #require(scanner.root.dirs.first)
        let b = try #require(a.dirs.first)
        let bSize = b.totalSize

        // Rescan b after adding a file, then swap it in.
        try write(root + "/a/b/f3", bytes: 30_000)
        let rescan = DiskScanner(path: b.path, parent: a)
        rescan.run()
        a.replaceDir(b, with: rescan.root)
        let grown = allocated(root + "/a/b/f3")
        #expect(rescan.root.totalSize == bSize + grown)
        #expect(scanner.root.totalSize == allocated(root + "/a/b/f1") + allocated(root + "/a/f2") + grown)
        #expect(scanner.root.totalFiles == 3)

        a.removeDir(rescan.root)
        #expect(scanner.root.totalSize == allocated(root + "/a/f2"))
        a.removeFile(named: "f2")
        #expect(scanner.root.totalSize == 0)
        #expect(scanner.root.totalFiles == 0)
    }
}
