import Foundation
import CCurl

private final class TransferContext {
    var sink: ((UnsafeRawPointer, Int) -> Int)?
    var source: ((UnsafeMutableRawPointer, Int) -> Int)?
    var progress: ((Int64, Int64) -> Bool)?
    var cancelled = false
}

private let writeThunk: @convention(c) (UnsafeMutablePointer<CChar>?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, ud in
    guard let ptr, let ud else { return 0 }
    let ctx = Unmanaged<TransferContext>.fromOpaque(ud).takeUnretainedValue()
    let total = size * nmemb
    return ctx.sink?(UnsafeRawPointer(ptr), total) ?? total
}

private let readThunk: @convention(c) (UnsafeMutablePointer<CChar>?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, ud in
    guard let ptr, let ud else { return 0 }
    let ctx = Unmanaged<TransferContext>.fromOpaque(ud).takeUnretainedValue()
    return ctx.source?(UnsafeMutableRawPointer(ptr), size * nmemb) ?? 0
}

private let xferThunk: @convention(c) (UnsafeMutableRawPointer?, curl_off_t, curl_off_t, curl_off_t, curl_off_t) -> Int32 = { ud, dlTotal, dlNow, ulTotal, ulNow in
    guard let ud else { return 0 }
    let ctx = Unmanaged<TransferContext>.fromOpaque(ud).takeUnretainedValue()
    guard let progress = ctx.progress else { return 0 }
    let done = dlNow > 0 ? Int64(dlNow) : Int64(ulNow)
    let total = dlTotal > 0 ? Int64(dlTotal) : Int64(ulTotal)
    if !progress(done, total) {
        ctx.cancelled = true
        return 1                                  // aborts the transfer
    }
    return 0
}

/// FTP and explicit-TLS FTPS on top of the libcurl that ships with macOS.
/// One easy handle per session keeps the control connection warm between calls.
final class FTPClient: RemoteFS {
    private let profile: ServerProfile
    private var handle: UnsafeMutableRawPointer?
    private var password: String = ""
    private var entryPath: String = "/"

    init(profile: ServerProfile) {
        self.profile = profile
    }

    deinit { disconnect() }

    // MARK: - Connection

    func connect(password: String?) throws {
        self.password = password ?? ""
        handle = curl_easy_init()
        guard handle != nil else { throw FerryError.transport("libcurl недоступен") }

        // A cheap round trip that proves the credentials and gives us the
        // server's entry directory.
        let ctx = TransferContext()
        ctx.sink = { _, n in n }
        try perform(url: url(for: "/", directory: true), ctx: ctx) { h in
            ferry_setopt_long(h, CURLOPT_NOBODY, 1)
        }

        var raw: UnsafeMutablePointer<CChar>?
        ferry_getinfo_str(handle, CURLINFO_FTP_ENTRY_PATH, &raw)
        if let raw, let s = String(validatingCString: raw), !s.isEmpty {
            entryPath = s
        }
    }

    func disconnect() {
        if let handle { curl_easy_cleanup(handle) }
        handle = nil
    }

    func currentDirectory() throws -> String {
        profile.remotePath.isEmpty ? entryPath : profile.remotePath
    }

    // MARK: - curl plumbing

    private func escape(_ s: String) -> String {
        guard let handle, let e = curl_easy_escape(handle, s, Int32(s.utf8.count)) else { return s }
        defer { curl_free(e) }
        return String(cString: e)
    }

    /// curl treats a single leading slash as "relative to the login directory",
    /// so absolute paths need the double slash form: ftp://host//abs/path.
    private func url(for path: String, directory: Bool) -> String {
        let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
        let encoded = path.split(separator: "/").map { escape(String($0)) }.joined(separator: "/")
        var s = "ftp://\(host):\(profile.port)//\(encoded)"
        if directory && !s.hasSuffix("/") { s += "/" }
        return s
    }

    private func applyCommonOptions(_ h: UnsafeMutableRawPointer) {
        ferry_setopt_long(h, CURLOPT_CONNECTTIMEOUT, 15)
        ferry_setopt_long(h, CURLOPT_SERVER_RESPONSE_TIMEOUT, 30)
        ferry_setopt_long(h, CURLOPT_NOSIGNAL, 1)
        ferry_setopt_long(h, CURLOPT_FTP_FILEMETHOD, Int(CURLFTPMETHOD_SINGLECWD.rawValue))
        ferry_setopt_str(h, CURLOPT_USERNAME, profile.username.isEmpty ? "anonymous" : profile.username)
        ferry_setopt_str(h, CURLOPT_PASSWORD, password)

        if profile.passive {
            ferry_setopt_long(h, CURLOPT_FTP_USE_EPSV, 1)
        } else {
            ferry_setopt_str(h, CURLOPT_FTPPORT, "-")
        }

        if profile.proto == .ftps {
            ferry_setopt_long(h, CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue))
            ferry_setopt_long(h, CURLOPT_FTP_SSL_CCC, Int(CURLFTPSSL_CCC_NONE.rawValue))
            ferry_setopt_long(h, CURLOPT_SSL_VERIFYPEER, 0)
            ferry_setopt_long(h, CURLOPT_SSL_VERIFYHOST, 0)
        } else {
            ferry_setopt_long(h, CURLOPT_USE_SSL, Int(CURLUSESSL_NONE.rawValue))
        }
    }

    /// Runs one request on the shared handle. `configure` adds per-call options;
    /// everything is reset afterwards so the handle stays reusable.
    private func perform(url: String,
                         ctx: TransferContext,
                         quote: [String] = [],
                         configure: (UnsafeMutableRawPointer) -> Void) throws {
        guard let h = handle else { throw FerryError.notConnected }

        curl_easy_reset(h)
        applyCommonOptions(h)
        ferry_setopt_str(h, CURLOPT_URL, url)

        let boxed = Unmanaged.passUnretained(ctx).toOpaque()
        ferry_setopt_write_cb(h, CURLOPT_WRITEFUNCTION, writeThunk)
        ferry_setopt_ptr(h, CURLOPT_WRITEDATA, boxed)
        ferry_setopt_read_cb(h, CURLOPT_READFUNCTION, readThunk)
        ferry_setopt_ptr(h, CURLOPT_READDATA, boxed)

        if ctx.progress != nil {
            ferry_setopt_long(h, CURLOPT_NOPROGRESS, 0)
            ferry_setopt_xfer_cb(h, CURLOPT_XFERINFOFUNCTION, xferThunk)
            ferry_setopt_ptr(h, CURLOPT_XFERINFODATA, boxed)
        }

        var slist: UnsafeMutablePointer<curl_slist>?
        for cmd in quote { slist = curl_slist_append(slist, cmd) }
        if slist != nil { ferry_setopt_slist(h, CURLOPT_QUOTE, slist) }
        defer { if slist != nil { curl_slist_free_all(slist) } }

        // curl writes into this buffer during perform, so it must outlive the
        // call — an array's temporary pointer would dangle.
        let errbuf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(CURL_ERROR_SIZE))
        errbuf.initialize(repeating: 0, count: Int(CURL_ERROR_SIZE))
        defer { errbuf.deallocate() }
        ferry_setopt_ptr(h, CURLOPT_ERRORBUFFER, errbuf)

        configure(h)

        let rc = curl_easy_perform(h)
        ferry_setopt_ptr(h, CURLOPT_ERRORBUFFER, nil)

        guard rc == CURLE_OK else {
            if ctx.cancelled || rc == CURLE_ABORTED_BY_CALLBACK { throw FerryError.cancelled }
            let detail = String(cString: errbuf)
            let fallback = String(cString: curl_easy_strerror(rc))
            let msg = detail.isEmpty ? fallback : detail
            if rc == CURLE_LOGIN_DENIED { throw FerryError.auth(msg) }
            throw FerryError.transport(msg)
        }
    }

    // MARK: - Listing

    func list(_ path: String) throws -> [RemoteFile] {
        // MLSD is machine-readable; plenty of old servers still only do LIST.
        if let mlsd = try? rawListing(path, command: "MLSD"), !mlsd.isEmpty {
            let parsed = parseMLSD(mlsd, base: path)
            if !parsed.isEmpty { return parsed }
        }
        let raw = try rawListing(path, command: nil)
        return parseUnixList(raw, base: path)
    }

    private func rawListing(_ path: String, command: String?) throws -> String {
        var buffer = Data()
        let ctx = TransferContext()
        ctx.sink = { ptr, n in
            buffer.append(UnsafeRawBufferPointer(start: ptr, count: n).bindMemory(to: UInt8.self))
            return n
        }
        try perform(url: url(for: path, directory: true), ctx: ctx) { h in
            if let command { ferry_setopt_str(h, CURLOPT_CUSTOMREQUEST, command) }
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    private func parseMLSD(_ text: String, base: String) -> [RemoteFile] {
        var out: [RemoteFile] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let facts = line[line.startIndex..<space]
            let name = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != ".", name != ".." else { continue }

            var type = "", size: Int64 = 0, modify: Date?
            for fact in facts.split(separator: ";") {
                let kv = fact.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "type":   type = kv[1].lowercased()
                case "size":   size = Int64(kv[1]) ?? 0
                case "modify": modify = parseMLSDDate(String(kv[1]))
                default:       break
                }
            }
            if type == "cdir" || type == "pdir" { continue }

            out.append(RemoteFile(
                name: name,
                path: remoteJoin(base, name),
                kind: type == "dir" ? .directory : (type.hasPrefix("os.unix=slink") ? .symlink : .file),
                size: size,
                modified: modify,
                permissions: ""
            ))
        }
        return out
    }

    private func parseMLSDDate(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: String(s.prefix(14)))
    }

    private func parseUnixList(_ text: String, base: String) -> [RemoteFile] {
        var out: [RemoteFile] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.count > 10 else { continue }

            // drwxr-xr-x 2 owner group 4096 Jan 12 10:30 name with spaces
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let perms = String(parts[0])
            guard let first = perms.first, "dl-".contains(first) else { continue }

            let size = Int64(parts[4]) ?? 0
            let name = nameAfterDateField(line: line, parts: parts)
            guard !name.isEmpty, name != ".", name != ".." else { continue }

            let kind: RemoteFile.Kind = first == "d" ? .directory : (first == "l" ? .symlink : .file)
            let display = kind == .symlink ? String(name.split(separator: " -> ").first ?? "") : name

            out.append(RemoteFile(
                name: display,
                path: remoteJoin(base, display),
                kind: kind,
                size: size,
                modified: parseListDate(parts),
                permissions: perms
            ))
        }
        return out
    }

    /// Names may contain spaces, so slice the original line after the 8th field
    /// rather than rejoining the split parts.
    private func nameAfterDateField(line: String, parts: [Substring]) -> String {
        var idx = line.startIndex
        var field = 0
        var inSpace = false
        while idx < line.endIndex, field < 8 {
            if line[idx] == " " {
                if !inSpace { field += 1; inSpace = true }
            } else {
                inSpace = false
            }
            idx = line.index(after: idx)
        }
        while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
        return String(line[idx...]).trimmingCharacters(in: .whitespaces)
    }

    private func parseListDate(_ parts: [Substring]) -> Date? {
        let month = String(parts[5]), day = String(parts[6]), last = String(parts[7])
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        if last.contains(":") {
            fmt.dateFormat = "yyyy MMM d HH:mm"
            let year = Calendar.current.component(.year, from: Date())
            return fmt.date(from: "\(year) \(month) \(day) \(last)")
        }
        fmt.dateFormat = "yyyy MMM d"
        return fmt.date(from: "\(last) \(month) \(day)")
    }

    // MARK: - Transfers

    func download(remote: String, to local: URL, size: Int64, progress: (Int64, Int64) -> Bool) throws {
        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: local.path) else {
            throw FerryError.local("Не удалось создать файл \(local.lastPathComponent)")
        }
        defer { try? out.close() }

        let ctx = TransferContext()
        ctx.sink = { ptr, n in
            let data = Data(UnsafeRawBufferPointer(start: ptr, count: n))
            do { try out.write(contentsOf: data) } catch { return 0 }
            return n
        }
        do {
            try withoutActuallyEscaping(progress) { escaping in
                ctx.progress = escaping
                defer { ctx.progress = nil }        // must not outlive the block
                try perform(url: url(for: remote, directory: false), ctx: ctx) { _ in }
            }
        } catch {
            try? FileManager.default.removeItem(at: local)
            throw error
        }
    }

    func upload(local: URL, to remote: String, progress: (Int64, Int64) -> Bool) throws {
        guard let input = FileHandle(forReadingAtPath: local.path) else {
            throw FerryError.local("Не удалось открыть \(local.lastPathComponent)")
        }
        defer { try? input.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: local.path)
        let total = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        let ctx = TransferContext()
        ctx.source = { buf, capacity in
            guard let chunk = try? input.read(upToCount: capacity), !chunk.isEmpty else { return 0 }
            chunk.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: chunk.count)
            return chunk.count
        }
        try withoutActuallyEscaping(progress) { escaping in
            ctx.progress = escaping
            defer { ctx.progress = nil }            // must not outlive the block
            try perform(url: url(for: remote, directory: false), ctx: ctx) { h in
                ferry_setopt_long(h, CURLOPT_UPLOAD, 1)
                ferry_setopt_off(h, CURLOPT_INFILESIZE_LARGE, curl_off_t(total))
            }
        }
    }

    // MARK: - Mutations

    /// Quote commands run after a CWD into `workdir`. Using the target's parent
    /// rather than "/" matters on servers that refuse to change to the root.
    private func runQuote(_ commands: [String], in workdir: String) throws {
        let ctx = TransferContext()
        ctx.sink = { _, n in n }
        try perform(url: url(for: workdir, directory: true), ctx: ctx, quote: commands) { h in
            ferry_setopt_long(h, CURLOPT_NOBODY, 1)
        }
    }

    func rename(_ from: String, to: String) throws {
        try runQuote(["RNFR \(from)", "RNTO \(to)"], in: remoteParent(from))
    }

    func delete(_ path: String, isDirectory: Bool) throws {
        if isDirectory {
            for child in (try? list(path)) ?? [] {
                try delete(child.path, isDirectory: child.isDirectory)
            }
            try runQuote(["RMD \(path)"], in: remoteParent(path))
        } else {
            try runQuote(["DELE \(path)"], in: remoteParent(path))
        }
    }

    func makeDirectory(_ path: String) throws {
        try runQuote(["MKD \(path)"], in: remoteParent(path))
    }
}
