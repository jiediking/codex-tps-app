import Darwin
import Darwin.membership
import Foundation

enum DesktopPathSecurity {
    static func directory(_ url: URL, privateToUser: Bool = false) throws -> Int32 {
        var path = url.path
        // These Darwin aliases are installed in the protected system root.
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), !components.isEmpty, !path.contains("\0"),
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw RelayError.unsafeDesktopPath
        }
        let options = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var parent = Darwin.open("/", options)
        guard parent >= 0 else { throw RelayError.unsafeDesktopPath }
        do {
            for (index, part) in components.enumerated() {
                let name = String(part)
                let leaf = index == components.count - 1
                let child = openat(parent, name, options)
                if child < 0, errno == ENOENT { throw POSIXError(.ENOENT) }
                guard child >= 0 else { throw RelayError.unsafeDesktopPath }
                Darwin.close(parent)
                parent = child
                var info = stat()
                guard fstat(child, &info) == 0, info.st_uid == 0 || info.st_uid == getuid(),
                      info.st_mode & 0o022 == 0 || (!leaf && info.st_mode & S_ISVTX != 0),
                      !(leaf && privateToUser) || (info.st_uid == getuid() && info.st_mode & 0o077 == 0)
                else { throw RelayError.unsafeDesktopPath }
                try verifyACL(child, privateToUser: leaf && privateToUser)
            }
            return parent
        } catch {
            Darwin.close(parent)
            throw error
        }
    }

    private static func verifyACL(_ fd: Int32, privateToUser: Bool = false) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw RelayError.unsafeDesktopPath }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var index = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, index, &entry) == 0, let entry {
            index = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = acl_tag_t(rawValue: 0)
            guard acl_get_tag_type(entry, &tag) == 0 else { throw RelayError.unsafeDesktopPath }
            if tag == ACL_EXTENDED_DENY { continue }
            var permissions: acl_permset_t?
            guard tag == ACL_EXTENDED_ALLOW, acl_get_permset(entry, &permissions) == 0,
                  let permissions else {
                throw RelayError.unsafeDesktopPath
            }
            var restricted = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE_CHILD, ACL_DELETE,
                              ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
            if privateToUser { restricted.append(ACL_SEARCH) }
            if restricted.allSatisfy({ acl_get_perm_np(permissions, $0) == 0 }) { continue }
            guard isTrustedPrincipal(entry) else { throw RelayError.unsafeDesktopPath }
        }
    }

    private static func isTrustedPrincipal(_ entry: acl_entry_t) -> Bool {
        guard let qualifier = acl_get_qualifier(entry) else { return false }
        defer { acl_free(qualifier) }
        let entryID = UnsafeRawBufferPointer(start: qualifier, count: MemoryLayout<uuid_t>.size)
        var userID = [UInt8](repeating: 0, count: entryID.count)
        for uid in [getuid(), 0] {
            if mbr_uid_to_uuid(uid, &userID) == 0, entryID.elementsEqual(userID) { return true }
        }
        return false
    }
}
