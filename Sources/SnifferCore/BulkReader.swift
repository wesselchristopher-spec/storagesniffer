import Darwin

/// Lists a directory with `getattrlistbulk(2)`, which returns names, types and allocated sizes
/// for many entries per system call. This is several times faster than `readdir` + `lstat`.
/// Each worker thread owns one reader and reuses its buffer.
final class BulkReader {
    enum Kind {
        case file, directory, symlink, other
    }

    struct Entry {
        var name: String
        var kind: Kind
        var allocatedSize: Int64
        var linkCount: UInt32
        var fileID: UInt64
        var device: Int32
        var isMountPoint: Bool
        /// The file may share blocks with an APFS clone.
        var mayShareBlocks: Bool
    }

    enum Result {
        case ok, denied, error
        /// The folder is the root of a grafted disk image (like the OS cryptexes in Preboot).
        /// Its contents are stored inside an image file that is counted separately.
        case graft
    }

    /// APFS object id of a filesystem's root directory.
    private static let rootObjectID: UInt64 = 2

    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var attrs: attrlist
    private var dirFD: Int32 = -1

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_ERROR)
        attrs.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        attrs.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // With FSOPT_ATTR_CMN_EXTENDED the fork group carries the extended common attributes.
        // Only the cheap flags here; private size needs an extent walk, so it is fetched
        // separately for the few files that may share blocks (see `cloneInfo`).
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
    }

    deinit {
        buffer.deallocate()
    }

    func read(path: String, isRoot: Bool, _ body: (Entry) -> Void) -> Result {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            return errno == EACCES || errno == EPERM ? .denied : .error
        }
        defer { close(fd) }
        if !isRoot && isGraftRoot(fd) { return .graft }
        dirFD = fd
        defer { dirFD = -1 }

        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count == 0 { return .ok }
            if count < 0 {
                return errno == EACCES || errno == EPERM ? .denied : .error
            }
            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                if let entry = parse(entryStart + 4) {
                    body(entry)
                }
                entryStart += length
            }
        }
    }

    /// Private (unshared) bytes and clone family of a file in the directory being read.
    /// Only valid inside the `read` callback.
    func cloneInfo(name: String) -> (privateSize: Int64, cloneID: UInt64)? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)
        var out = (UInt32(0), Int64(0), UInt64(0))
        let size = MemoryLayout.size(ofValue: out)
        let ok = withUnsafeMutableBytes(of: &out) { raw in
            getattrlistat(dirFD, name, &list, raw.baseAddress, size,
                          UInt(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0
        }
        guard ok else { return nil }
        return withUnsafeBytes(of: &out) { raw in
            ((raw.baseAddress! + 4).loadUnaligned(as: Int64.self),
             (raw.baseAddress! + 12).loadUnaligned(as: UInt64.self))
        }
    }

    /// A graft root reports the filesystem-root object id while its file id says otherwise.
    /// Real volume roots are reached through mount points and report a matching file id.
    private func isGraftRoot(_ fd: Int32) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_FILEID)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var out = (UInt32(0), UInt64(0), UInt64(0))
        let size = MemoryLayout.size(ofValue: out)
        let ok = withUnsafeMutableBytes(of: &out) { raw in
            fgetattrlist(fd, &list, raw.baseAddress, size, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0
        }
        guard ok else { return false }
        let fileID = withUnsafeBytes(of: &out) { ($0.baseAddress! + 4).loadUnaligned(as: UInt64.self) }
        let objectID = withUnsafeBytes(of: &out) { ($0.baseAddress! + 12).loadUnaligned(as: UInt64.self) }
        return objectID == Self.rootObjectID && fileID != Self.rootObjectID
    }

    /// Attributes are packed in a fixed order: returned-attribute set first, then each group
    /// in bit order. Only attributes flagged in the returned set are present.
    private func parse(_ start: UnsafeRawPointer) -> Entry? {
        var p = start
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size

        let common = returned.commonattr
        var entry = Entry(name: "", kind: .other, allocatedSize: 0, linkCount: 1,
                          fileID: 0, device: 0, isMountPoint: false, mayShareBlocks: false)

        if common & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let ref = p.loadUnaligned(as: attrreference_t.self)
            let namePtr = (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            entry.name = String(cString: namePtr)
            p += MemoryLayout<attrreference_t>.size
        }
        if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            entry.device = p.loadUnaligned(as: Int32.self)
            p += MemoryLayout<dev_t>.size
        }
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            switch Int(p.loadUnaligned(as: fsobj_type_t.self)) {
            case Int(VREG.rawValue): entry.kind = .file
            case Int(VDIR.rawValue): entry.kind = .directory
            case Int(VLNK.rawValue): entry.kind = .symlink
            default: entry.kind = .other
            }
            p += MemoryLayout<fsobj_type_t>.size
        }
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            entry.fileID = p.loadUnaligned(as: UInt64.self)
            p += MemoryLayout<UInt64>.size
        }
        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let err = p.loadUnaligned(as: UInt32.self)
            p += MemoryLayout<UInt32>.size
            if err != 0 { return nil }
        }
        if entry.name.isEmpty { return nil }

        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            let status = p.loadUnaligned(as: UInt32.self)
            entry.isMountPoint = status & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            p += MemoryLayout<UInt32>.size
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = p.loadUnaligned(as: UInt32.self)
            p += MemoryLayout<UInt32>.size
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocatedSize = p.loadUnaligned(as: off_t.self)
            p += MemoryLayout<off_t>.size
        }
        let ext = returned.forkattr
        if ext & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
            let flags = p.loadUnaligned(as: UInt64.self)
            entry.mayShareBlocks = flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
            p += MemoryLayout<UInt64>.size
        }
        return entry
    }
}
