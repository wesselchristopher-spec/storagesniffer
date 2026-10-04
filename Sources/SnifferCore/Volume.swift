import Darwin
import Foundation

/// Capacity of the disk a path lives on.
public struct VolumeInfo: Sendable {
    public var name: String
    public var total: Int64
    /// Free space, not counting purgeable data that macOS could clear on demand.
    public var free: Int64
    /// Free space including purgeable data (caches, iCloud-evictable files, local snapshots).
    public var availableForImportantUsage: Int64

    public var used: Int64 { total - free }
    public var purgeable: Int64 { max(0, availableForImportantUsage - free) }

    public init?(path: String) {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity
        else { return nil }
        name = v.volumeLocalizedName ?? "Disk"
        self.total = Int64(total)
        free = Int64(v.volumeAvailableCapacity ?? 0)
        availableForImportantUsage = v.volumeAvailableCapacityForImportantUsage ?? free
    }
}

public enum Permissions {
    /// Whether the app has Full Disk Access. Without it, macOS hides Mail, Safari, Messages,
    /// other apps' containers and Time Machine data, so the scan undercounts.
    public static var hasFullDiskAccess: Bool {
        let home = NSHomeDirectory()
        let probes = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Containers/com.apple.stocks",
        ]
        for path in probes {
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }
}
