import Foundation

/// One-way flag shared with the watchdog thread.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }
}

/// SFTP over the system `ssh` binary: we ask for the `sftp` subsystem and speak
/// protocol v3 on its stdin/stdout. That buys us the user's ~/.ssh config,
/// known_hosts and ssh-agent for free, with no third-party crypto.
final class SFTPClient: RemoteFS {
    private let profile: ServerProfile

    private var process: Process?
    private var toServer: FileHandle?
    private var fromServer: FileHandle?
    private var askpassDir: URL?

    private var nextID: UInt32 = 1
    private let stderrLock = NSLock()
    private var stderrText = ""

    /// 32 KiB is the largest read every v3 server is required to honour.
    private let chunkSize = 32_768
    /// Requests kept in flight; latency is what kills SFTP throughput.
    private let window = 16

    init(profile: ServerProfile) {
        self.profile = profile
    }

    deinit { disconnect() }

    // MARK: - Connection

    func connect(password: String?) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args: [String] = [
            "-p", String(profile.port),
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "LogLevel=ERROR",
        ]

        var env = ProcessInfo.processInfo.environment

        switch profile.auth {
        case .password:
            args += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
            ]
            guard let password, !password.isEmpty else {
                throw FerryError.auth("не задан пароль")
            }
            let dir = try makeAskpass(password: password)
            askpassDir = dir
            env["SSH_ASKPASS"] = dir.appendingPathComponent("askpass").path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["FERRY_PW"] = dir.appendingPathComponent("pw").path
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"

        case .keyFile:
            guard !profile.privateKeyPath.isEmpty else {
                throw FerryError.auth("не выбран файл ключа")
            }
            args += [
                "-i", (profile.privateKeyPath as NSString).expandingTildeInPath,
                "-o", "IdentitiesOnly=yes",
                "-o", "PreferredAuthentications=publickey",
                "-o", "BatchMode=yes",
            ]

        case .agent:
            args += ["-o", "BatchMode=yes"]
        }

        let target = profile.username.isEmpty ? profile.host : "\(profile.username)@\(profile.host)"
        args += ["-s", target, "sftp"]
        proc.arguments = args
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            self.stderrLock.lock()
            self.stderrText += String(decoding: d, as: UTF8.self)
            self.stderrLock.unlock()
        }

        do {
            try proc.run()
        } catch {
            cleanupAskpass()
            throw FerryError.transport("Не удалось запустить ssh: \(error.localizedDescription)")
        }

        process = proc
        toServer = inPipe.fileHandleForWriting
        fromServer = outPipe.fileHandleForReading

        // A hung login would block the handshake read forever, so arm a watchdog
        // that kills ssh and turns the block into a clean EOF.
        let handshakeDone = AtomicFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
            if !handshakeDone.value { proc.terminate() }
        }

        do {
            try handshake()
            handshakeDone.set()
        } catch {
            handshakeDone.set()
            let diag = drainStderr()
            disconnect()
            if diag.localizedCaseInsensitiveContains("permission denied") {
                throw FerryError.auth("сервер отклонил учётные данные")
            }
            // A changed host key is a security warning, not a typo — say so plainly.
            if diag.localizedCaseInsensitiveContains("host key")
                || diag.localizedCaseInsensitiveContains("host identification") {
                throw FerryError.transport("""
                Ключ сервера изменился с прошлого подключения.                 Если сервер переустанавливали — выполните в Терминале:                 ssh-keygen -R '[\(profile.host)]:\(profile.port)'
                """)
            }
            if !diag.isEmpty {
                throw FerryError.transport(diag.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw error
        }

        cleanupAskpass()
    }

    func disconnect() {
        toServer?.closeFile()
        fromServer?.closeFile()
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        toServer = nil
        fromServer = nil
        cleanupAskpass()
    }

    private func makeAskpass(password: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ferry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let pwURL = dir.appendingPathComponent("pw")
        try Data(password.utf8).write(to: pwURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pwURL.path)

        let script = "#!/bin/sh\ncat \"$FERRY_PW\"\n"
        let scriptURL = dir.appendingPathComponent("askpass")
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return dir
    }

    private func cleanupAskpass() {
        if let dir = askpassDir { try? FileManager.default.removeItem(at: dir) }
        askpassDir = nil
    }

    private func drainStderr() -> String {
        stderrLock.lock(); defer { stderrLock.unlock() }
        return stderrText
    }

    // MARK: - Framing

    private func send(_ data: Data) throws {
        guard let toServer else { throw FerryError.notConnected }
        do { try toServer.write(contentsOf: data) }
        catch { throw FerryError.transport("Соединение закрыто") }
    }

    private func readExactly(_ n: Int) throws -> Data {
        guard let fromServer else { throw FerryError.notConnected }
        var out = Data()
        out.reserveCapacity(n)
        while out.count < n {
            let chunk = (try? fromServer.read(upToCount: n - out.count)) ?? nil
            guard let chunk, !chunk.isEmpty else {
                throw FerryError.transport("Соединение с сервером потеряно")
            }
            out.append(chunk)
        }
        return out
    }

    private struct Packet {
        var type: UInt8
        var reader: SFTPReader
    }

    private func readPacket() throws -> Packet {
        let header = try readExactly(4)
        let len = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard len > 0, len < 64 * 1024 * 1024 else {
            throw FerryError.protocolError("Некорректная длина пакета")
        }
        let body = try readExactly(Int(len))
        var r = SFTPReader(body)
        let type = try r.byte()
        return Packet(type: type, reader: r)
    }

    private func newID() -> UInt32 {
        defer { nextID &+= 1 }
        return nextID
    }

    private func handshake() throws {
        var w = SFTPWriter()
        w.uint32(3)                                  // protocol version
        try send(w.framed(type: .initPacket, requestID: nil))

        let pkt = try readPacket()
        guard pkt.type == FXP.version.rawValue else {
            throw FerryError.protocolError("Сервер не ответил на INIT")
        }
    }

    /// Read packets until the one matching `id` arrives.
    private func awaitReply(id: UInt32) throws -> Packet {
        while true {
            var pkt = try readPacket()
            let rid = try pkt.reader.uint32()
            if rid == id { return pkt }
        }
    }

    @discardableResult
    private func expectStatus(id: UInt32, allowEOF: Bool = false) throws -> FXStatus {
        var pkt = try awaitReply(id: id)
        guard pkt.type == FXP.status.rawValue else {
            throw FerryError.protocolError("Ожидался STATUS")
        }
        let code = try pkt.reader.uint32()
        let status = FXStatus(rawValue: code) ?? .failure
        if status == .ok { return status }
        if status == .eof && allowEOF { return status }
        let detail = (try? pkt.reader.string()) ?? ""
        throw FerryError.protocolError(detail.isEmpty ? status.message : detail)
    }

    private func openHandle(type: FXP, build: (inout SFTPWriter) -> Void) throws -> Data {
        let id = newID()
        var w = SFTPWriter()
        build(&w)
        try send(w.framed(type: type, requestID: id))

        var pkt = try awaitReply(id: id)
        if pkt.type == FXP.status.rawValue {
            let code = try pkt.reader.uint32()
            let status = FXStatus(rawValue: code) ?? .failure
            let detail = (try? pkt.reader.string()) ?? ""
            throw FerryError.protocolError(detail.isEmpty ? status.message : detail)
        }
        guard pkt.type == FXP.handle.rawValue else {
            throw FerryError.protocolError("Ожидался HANDLE")
        }
        return try pkt.reader.blob()
    }

    private func closeHandle(_ handle: Data) {
        let id = newID()
        var w = SFTPWriter()
        w.blob(handle)
        try? send(w.framed(type: .close, requestID: id))
        _ = try? expectStatus(id: id)
    }

    // MARK: - RemoteFS

    func currentDirectory() throws -> String {
        try realpath(profile.remotePath.isEmpty ? "." : profile.remotePath)
    }

    func realpath(_ path: String) throws -> String {
        let id = newID()
        var w = SFTPWriter()
        w.string(path)
        try send(w.framed(type: .realpath, requestID: id))

        var pkt = try awaitReply(id: id)
        if pkt.type == FXP.status.rawValue { return path }
        guard pkt.type == FXP.name.rawValue else {
            throw FerryError.protocolError("Ожидался NAME")
        }
        let count = try pkt.reader.uint32()
        guard count >= 1 else { return path }
        return try pkt.reader.string()
    }

    func list(_ path: String) throws -> [RemoteFile] {
        let handle = try openHandle(type: .opendir) { $0.string(path) }
        defer { closeHandle(handle) }

        var files: [RemoteFile] = []
        while true {
            let id = newID()
            var w = SFTPWriter()
            w.blob(handle)
            try send(w.framed(type: .readdir, requestID: id))

            var pkt = try awaitReply(id: id)
            if pkt.type == FXP.status.rawValue {
                let code = try pkt.reader.uint32()
                let status = FXStatus(rawValue: code) ?? .failure
                if status == .eof { break }
                let detail = (try? pkt.reader.string()) ?? ""
                throw FerryError.protocolError(detail.isEmpty ? status.message : detail)
            }
            guard pkt.type == FXP.name.rawValue else {
                throw FerryError.protocolError("Ожидался NAME")
            }

            let count = try pkt.reader.uint32()
            for _ in 0..<count {
                let name = try pkt.reader.string()
                let longname = try pkt.reader.string()
                let attrs = try pkt.reader.attrs()
                if name == "." || name == ".." { continue }

                let kind: RemoteFile.Kind
                if attrs.isDirectory { kind = .directory }
                else if attrs.isSymlink { kind = .symlink }
                else if attrs.permissions != nil { kind = .file }
                else { kind = longname.hasPrefix("d") ? .directory : .file }

                files.append(RemoteFile(
                    name: name,
                    path: remoteJoin(path, name),
                    kind: kind,
                    size: attrs.size ?? 0,
                    modified: attrs.mtime,
                    permissions: String(longname.prefix(10))
                ))
            }
        }
        return files
    }

    func makeDirectory(_ path: String) throws {
        let id = newID()
        var w = SFTPWriter()
        w.string(path)
        w.uint32(0)                                   // empty attrs
        try send(w.framed(type: .mkdir, requestID: id))
        try expectStatus(id: id)
    }

    func rename(_ from: String, to: String) throws {
        let id = newID()
        var w = SFTPWriter()
        w.string(from)
        w.string(to)
        try send(w.framed(type: .rename, requestID: id))
        try expectStatus(id: id)
    }

    func delete(_ path: String, isDirectory: Bool) throws {
        if isDirectory {
            // Depth-first: v3 has no recursive remove.
            for child in (try? list(path)) ?? [] {
                try delete(child.path, isDirectory: child.isDirectory)
            }
        }
        let id = newID()
        var w = SFTPWriter()
        w.string(path)
        try send(w.framed(type: isDirectory ? .rmdir : .remove, requestID: id))
        try expectStatus(id: id)
    }

    func download(remote: String, to local: URL, size: Int64, progress: (Int64, Int64) -> Bool) throws {
        let handle = try openHandle(type: .open) { w in
            w.string(remote)
            w.uint32(SFTPOpenFlags.read)
            w.uint32(0)
        }
        defer { closeHandle(handle) }

        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: local.path) else {
            throw FerryError.local("Не удалось создать файл \(local.lastPathComponent)")
        }
        defer { try? out.close() }

        var requestOffset: Int64 = 0      // next offset to ask the server for
        var written: Int64 = 0            // bytes already on disk, in order
        var inflight: [(id: UInt32, offset: Int64)] = []
        var buffered: [Int64: Data] = [:] // out-of-order replies, keyed by offset
        var eof = false
        var resync = false
        var cancelled = false

        func pump() throws {
            while !eof && !resync && inflight.count < window {
                let id = newID()
                var w = SFTPWriter()
                w.blob(handle)
                w.uint64(UInt64(requestOffset))
                w.uint32(UInt32(chunkSize))
                try send(w.framed(type: .read, requestID: id))
                inflight.append((id, requestOffset))
                requestOffset += Int64(chunkSize)
            }
        }

        try pump()

        while !inflight.isEmpty {
            let next = inflight.removeFirst()
            var pkt = try awaitReply(id: next.id)

            if pkt.type == FXP.status.rawValue {
                let code = try pkt.reader.uint32()
                let status = FXStatus(rawValue: code) ?? .failure
                guard status == .eof else {
                    let detail = (try? pkt.reader.string()) ?? ""
                    throw FerryError.protocolError(detail.isEmpty ? status.message : detail)
                }
                eof = true
            } else if pkt.type == FXP.data.rawValue {
                let chunk = try pkt.reader.blob()
                // Reply older than the write cursor is a duplicate from a resync.
                if next.offset >= written {
                    buffered[next.offset] = chunk
                }
                // A reply shorter than requested leaves a hole in the window:
                // finish draining, then restart the window from the cursor.
                if chunk.count < chunkSize && !chunk.isEmpty {
                    resync = true
                }
            } else {
                throw FerryError.protocolError("Ожидался DATA")
            }

            while let piece = buffered.removeValue(forKey: written) {
                try out.write(contentsOf: piece)
                written += Int64(piece.count)
                if !progress(written, size) { cancelled = true }
            }

            if cancelled { break }

            if inflight.isEmpty && resync && !eof {
                buffered.removeAll()          // anything past the hole is refetched
                requestOffset = written
                resync = false
            }
            try pump()
        }

        if cancelled {
            for pending in inflight { _ = try? awaitReply(id: pending.id) }
            try? FileManager.default.removeItem(at: local)
            throw FerryError.cancelled
        }
    }

    func upload(local: URL, to remote: String, progress: (Int64, Int64) -> Bool) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: local.path)
        let total = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard let input = FileHandle(forReadingAtPath: local.path) else {
            throw FerryError.local("Не удалось открыть \(local.lastPathComponent)")
        }
        defer { try? input.close() }

        let handle = try openHandle(type: .open) { w in
            w.string(remote)
            w.uint32(SFTPOpenFlags.write | SFTPOpenFlags.creat | SFTPOpenFlags.trunc)
            w.uint32(0)
        }
        defer { closeHandle(handle) }

        var offset: Int64 = 0
        var acked: Int64 = 0
        var inflight: [(id: UInt32, bytes: Int)] = []
        var cancelled = false

        func drainOne() throws {
            guard !inflight.isEmpty else { return }
            let done = inflight.removeFirst()
            try expectStatus(id: done.id)
            acked += Int64(done.bytes)
            if !progress(acked, total) { cancelled = true }
        }

        while true {
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }

            let id = newID()
            var w = SFTPWriter()
            w.blob(handle)
            w.uint64(UInt64(offset))
            w.blob(chunk)
            try send(w.framed(type: .write, requestID: id))
            inflight.append((id, chunk.count))
            offset += Int64(chunk.count)

            if inflight.count >= window { try drainOne() }
            if cancelled { break }
        }

        while !inflight.isEmpty { try drainOne() }

        if cancelled {
            try? delete(remote, isDirectory: false)
            throw FerryError.cancelled
        }
    }
}
