import Foundation
import SnifferCore

// Usage: sniff [path] [--top N]
// Scans a folder, prints timing and the largest items. Used to benchmark the scanner and
// compare totals against `du -skx`.

var args = Array(CommandLine.arguments.dropFirst())
var top = 15
if let i = args.firstIndex(of: "--top"), i + 1 < args.count, let n = Int(args[i + 1]) {
    top = n
    args.removeSubrange(i...(i + 1))
}
let path = args.first.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()

let start = Date()
let scanner = DiskScanner(path: path)
scanner.run()
let elapsed = Date().timeIntervalSince(start)
let p = scanner.progress.snapshot
let root = scanner.root

print("Scanned \(path) in \(String(format: "%.2f", elapsed))s")
print("  \(Format.count(p.files)) files, \(Format.count(p.dirs)) folders, \(p.denied) unreadable")
print("  Total: \(Format.bytes(root.totalSize)) (\(root.totalSize) bytes, \(root.totalSize / 1024) KiB)")
print("  Rate: \(Format.count(Int64(Double(p.files + p.dirs) / max(elapsed, 0.001)))) items/s")
print()

struct Row {
    let name: String
    let size: Int64
    let isDir: Bool
}
var rows = root.dirs.map { Row(name: $0.name + "/", size: $0.totalSize, isDir: true) }
rows += root.files.map { Row(name: $0.name, size: $0.size, isDir: false) }
rows.sort { $0.size > $1.size }
for r in rows.prefix(top) {
    let size = Format.bytes(r.size).padding(toLength: 10, withPad: " ", startingAt: 0)
    print("  \(size) \(Format.percent(r.size, of: root.totalSize).padding(toLength: 6, withPad: " ", startingAt: 0)) \(r.name)")
}
