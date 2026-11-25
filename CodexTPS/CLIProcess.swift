import Darwin

enum CLIProcess {
    static func isRunning() -> Bool? {
        let uid = getuid()
        let estimatedBytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard estimatedBytes > 0 else { return nil }

        let entrySize = MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: Int(estimatedBytes) / entrySize + 32)
        let bytesRead = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesRead > 0 else { return nil }

        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(bytesRead) / entrySize) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize,
                  info.pbi_status != SZOMB,
                  info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0 else { continue }

            // The shared App Server is detached from the terminal.
            let name = withUnsafeBytes(of: info.pbi_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == "codex" || (name.hasPrefix("codex-") && name.hasSuffix("-apple-darwin")) {
                return true
            }
        }
        return Int(bytesRead) < pids.count * entrySize ? false : nil
    }
}
