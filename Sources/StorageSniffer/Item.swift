import Foundation
import SnifferCore

/// One entry shown in the treemap or list: a folder, a file, or a synthetic group.
struct Item: Identifiable {
    enum Kind {
        case folder(DirNode)
        case file(FileEntry)
        /// Many small items folded together so the view stays readable and fast.
        case smaller(count: Int)
        /// Used disk space the scan could not see.
        case hidden(Unseen)
    }

    enum Unseen: Hashable {
        /// Space macOS reports as purgeable: caches and local snapshots it frees on demand.
        case purgeable
        /// Everything else: APFS snapshots, protected system data, unreadable folders.
        case other
    }

    enum ID: Hashable {
        case folder(ObjectIdentifier)
        case file(ObjectIdentifier, String)
        case smaller(ObjectIdentifier)
        case hidden(Unseen)
    }

    let kind: Kind
    let name: String
    let size: Int64
    /// The folder that contains this item.
    let parent: DirNode

    var id: ID {
        switch kind {
        case .folder(let d): .folder(d.id)
        case .file(let f): .file(parent.id, f.name)
        case .smaller: .smaller(parent.id)
        case .hidden(let u): .hidden(u)
        }
    }

    var folder: DirNode? {
        if case .folder(let d) = kind { return d }
        return nil
    }

    var isFolder: Bool { folder != nil }

    /// Files and folders exist on disk and can be revealed or trashed.
    var isReal: Bool {
        switch kind {
        case .folder, .file: true
        default: false
        }
    }

    var path: String? {
        switch kind {
        case .folder(let d): d.path
        case .file(let f): parent.path(ofFile: f.name)
        default: nil
        }
    }

    var fileCount: Int64? {
        switch kind {
        case .folder(let d): d.totalFiles
        case .file: 1
        case .smaller(let n): Int64(n)
        case .hidden: nil
        }
    }

    var isScanning: Bool {
        if case .folder(let d) = kind { return !d.isComplete }
        return false
    }

    var symbol: String {
        switch kind {
        case .folder(let d):
            if d.state == .denied { return "lock.fill" }
            return FileKinds.folderSymbol(d.name)
        case .file(let f):
            if f.flags.contains(.symlink) { return "arrow.turn.up.right" }
            return FileKinds.symbol(for: f.name)
        case .smaller: return "square.grid.3x3.fill"
        case .hidden(.purgeable): return "arrow.3.trianglepath"
        case .hidden(.other): return "eye.slash.fill"
        }
    }

    /// Children of a folder, largest first. Reads only listed folders.
    static func children(of dir: DirNode) -> [Item] {
        guard dir.isListed else { return [] }
        var items: [Item] = []
        items.reserveCapacity(dir.dirs.count + dir.files.count)
        for d in dir.dirs {
            items.append(Item(kind: .folder(d), name: d.name, size: d.totalSize, parent: dir))
        }
        for f in dir.files {
            items.append(Item(kind: .file(f), name: f.name, size: f.size, parent: dir))
        }
        items.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        return items
    }
}

enum FileKinds {
    static func folderSymbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "app": return "app.fill"
        case "photoslibrary": return "photo.on.rectangle.angled"
        case "bundle", "framework", "plugin", "kext": return "shippingbox.fill"
        case "xcarchive", "xcodeproj", "xcworkspace": return "hammer.fill"
        default: return "folder.fill"
        }
    }

    static func symbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": return "film.fill"
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "raw", "dng", "cr2", "nef", "webp":
            return "photo.fill"
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "caf": return "music.note"
        case "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "tar": return "doc.zipper"
        case "dmg", "iso", "img", "sparseimage", "sparsebundle": return "externaldrive.fill"
        case "pkg", "ipa": return "shippingbox.fill"
        case "pdf": return "doc.richtext.fill"
        case "gguf", "safetensors", "bin", "pt", "onnx", "ckpt": return "cpu.fill"
        case "db", "sqlite", "sqlite3", "realm": return "cylinder.fill"
        case "log", "txt", "md": return "doc.text.fill"
        case "vmdk", "vdi", "qcow2", "raw-img": return "server.rack"
        default: return "doc.fill"
        }
    }
}
