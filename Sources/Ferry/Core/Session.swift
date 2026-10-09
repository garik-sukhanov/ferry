import Foundation

/// Cancellation is polled from the transfer thread, so it lives outside the
/// main-actor island.
final class CancelFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<UUID>()

    func cancel(_ id: UUID) {
        lock.lock(); ids.insert(id); lock.unlock()
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}

@MainActor
final class Session: ObservableObject {
    enum State: Equatable {
        case connecting, connected, failed(String)
    }

    let profile: ServerProfile

    @Published var state: State = .connecting
    @Published var path: String = "/"
    @Published var files: [RemoteFile] = []
    @Published var loading = false
    @Published var transfers: [Transfer] = []
    @Published var banner: String?

    /// Folder new downloads land in when the drop target is not the Finder.
    var downloadFolder: URL {
        if !profile.localPath.isEmpty {
            return URL(fileURLWithPath: (profile.localPath as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private let browse: Connection
    let transferConnection: Connection

    private var pending: [TransferJob] = []
    private var running = false
    private let cancelFlags = CancelFlags()

    init(profile: ServerProfile, password: String?) {
        self.profile = profile
        self.browse = Connection(profile: profile, password: password, label: "browse")
        self.transferConnection = Connection(profile: profile, password: password, label: "transfer")
    }

    // MARK: - Navigation

    func connect() {
        state = .connecting
        loading = true
        browse.perform({ client in
            let start = try client.currentDirectory()
            return (start, try client.list(start))
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let (start, items)):
                    self.path = start
                    self.files = Self.sorted(items)
                    self.state = .connected
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        })
    }

    func navigate(to newPath: String) {
        loading = true
        browse.perform({ try $0.list(newPath) }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let items):
                    self.path = newPath
                    self.files = Self.sorted(items)
                    self.state = .connected
                case .failure(let error):
                    self.report(error)
                }
            }
        })
    }

    func reload() { navigate(to: path) }

    func goUp() {
        guard path != "/" else { return }
        navigate(to: remoteParent(path))
    }

    private static func sorted(_ items: [RemoteFile]) -> [RemoteFile] {
        items.sorted {
            if $0.looksLikeDirectory != $1.looksLikeDirectory { return $0.looksLikeDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func report(_ error: Error) {
        if case FerryError.cancelled = error { return }
        banner = error.localizedDescription
    }

    // MARK: - Remote operations

    func rename(_ file: RemoteFile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != file.name else { return }
        let target = remoteJoin(remoteParent(file.path), trimmed)
        browse.perform({ try $0.rename(file.path, to: target) }, then: { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result { self?.report(error) }
                self?.reload()
            }
        })
    }

    func delete(_ items: [RemoteFile]) {
        guard !items.isEmpty else { return }
        let payload = items.map { ($0.path, $0.looksLikeDirectory) }
        browse.perform({ client in
            for (path, isDir) in payload { try client.delete(path, isDirectory: isDir) }
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result { self?.report(error) }
                self?.reload()
            }
        })
    }

    func makeDirectory(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = remoteJoin(path, trimmed)
        browse.perform({ try $0.makeDirectory(target) }, then: { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result { self?.report(error) }
                self?.reload()
            }
        })
    }

    // MARK: - Transfer queue

    func cancel(_ id: UUID) {
        cancelFlags.cancel(id)
        if let idx = transfers.firstIndex(where: { $0.id == id }), transfers[idx].state == .waiting {
            transfers[idx].state = .cancelled
            pending.removeAll { $0.id == id }
        }
    }

    func clearFinished() {
        transfers.removeAll { $0.isFinished }
    }

    /// Download the given entries (files or folders) into `destination`.
    func download(_ items: [RemoteFile], to destination: URL) {
        guard !items.isEmpty else { return }
        let roots = items.map { ($0.path, $0.name, $0.looksLikeDirectory, $0.size) }

        transferConnection.perform({ client -> [(String, Int64, URL)] in
            var plan: [(String, Int64, URL)] = []
            for (path, name, isDir, size) in roots {
                if isDir {
                    try Self.walkRemoteTree(client: client, remote: path,
                                        local: destination.appendingPathComponent(name),
                                        into: &plan)
                } else {
                    plan.append((path, size, destination.appendingPathComponent(name)))
                }
            }
            return plan
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let plan):
                    for (remote, size, local) in plan {
                        let unique = Self.uniqueURL(local)
                        var t = Transfer(name: unique.lastPathComponent, direction: .download)
                        t.total = size
                        self.transfers.append(t)
                        self.pending.append(TransferJob(id: t.id,
                            payload: .download(remote: remote, size: size, local: unique)))
                    }
                    self.pump()
                case .failure(let error):
                    self.report(error)
                }
            }
        })
    }

    static func walkRemoteTree(client: RemoteFS, remote: String, local: URL,
                                   into plan: inout [(String, Int64, URL)]) throws {
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for entry in try client.list(remote) {
            let childLocal = local.appendingPathComponent(entry.name)
            if entry.looksLikeDirectory {
                try walkRemoteTree(client: client, remote: entry.path, local: childLocal, into: &plan)
            } else {
                plan.append((entry.path, entry.size, childLocal))
            }
        }
    }

    /// Upload local files or folders into the current remote directory.
    func upload(_ urls: [URL], to remoteDir: String) {
        var jobs: [(UUID, TransferJob.Payload, String, Int64)] = []

        func addFile(_ url: URL, remote: String) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            jobs.append((UUID(), .upload(local: url, remote: remote), url.lastPathComponent, size))
        }

        func addTree(_ url: URL, remote: String) {
            jobs.append((UUID(), .makeRemoteDirectory(remote), url.lastPathComponent, 0))
            let children = (try? FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
                let childRemote = remoteJoin(remote, child.lastPathComponent)
                if isDir.boolValue { addTree(child, remote: childRemote) }
                else { addFile(child, remote: childRemote) }
            }
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let remote = remoteJoin(remoteDir, url.lastPathComponent)
            if isDir.boolValue { addTree(url, remote: remote) } else { addFile(url, remote: remote) }
        }

        for (id, payload, name, size) in jobs {
            if case .makeRemoteDirectory = payload {
                pending.append(TransferJob(id: id, payload: payload))
                continue                                   // silent, no UI row
            }
            var t = Transfer(name: name, direction: .upload)
            t.total = size
            transfers.append(t)
            pending.append(TransferJob(id: t.id, payload: payload))
        }
        pump()
    }

    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func pump() {
        guard !running, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        running = true

        if let idx = transfers.firstIndex(where: { $0.id == job.id }) {
            transfers[idx].state = .active
        }

        let jobID = job.id
        var lastTick = Date()
        var lastBytes: Int64 = 0

        let onProgress: (Int64, Int64) -> Bool = { [weak self] done, total in
            guard let self else { return false }
            let now = Date()
            let elapsed = now.timeIntervalSince(lastTick)
            if elapsed >= 0.1 {
                let speed = elapsed > 0 ? Double(done - lastBytes) / elapsed : 0
                lastTick = now
                lastBytes = done
                DispatchQueue.main.async {
                    guard let idx = self.transfers.firstIndex(where: { $0.id == jobID }) else { return }
                    self.transfers[idx].bytes = done
                    if total > 0 { self.transfers[idx].total = total }
                    self.transfers[idx].speed = speed
                }
            }
            return !self.cancelFlags.contains(jobID)
        }

        transferConnection.perform({ client in
            switch job.payload {
            case .download(let remote, let size, let local):
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try client.download(remote: remote, to: local, size: size, progress: onProgress)
            case .upload(let local, let remote):
                try client.upload(local: local, to: remote, progress: onProgress)
            case .makeRemoteDirectory(let remote):
                try? client.makeDirectory(remote)          // may already exist
            case .makeLocalDirectory(let url):
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                if let idx = self.transfers.firstIndex(where: { $0.id == jobID }) {
                    switch result {
                    case .success:
                        self.transfers[idx].state = .done
                        self.transfers[idx].bytes = max(self.transfers[idx].bytes, self.transfers[idx].total)
                    case .failure(let error):
                        if case FerryError.cancelled = error {
                            self.transfers[idx].state = .cancelled
                        } else {
                            self.transfers[idx].state = .failed(error.localizedDescription)
                        }
                    }
                }
                if case .upload = job.payload, self.pending.isEmpty { self.reload() }
                if case .makeRemoteDirectory = job.payload, self.pending.isEmpty { self.reload() }
                self.pump()
            }
        })
    }

    func close() {
        browse.close()
        transferConnection.close()
    }
}

// MARK: - Drag-out staging

extension Session {
    /// Fetch one entry for a Finder drop. Runs on the transfer connection and
    /// reports into the Progress object Finder is already showing.
    func stageForDrag(_ file: RemoteFile,
                      to target: URL,
                      progress: Progress,
                      completion: @escaping (Result<URL, Error>) -> Void) {
        var row = Transfer(name: file.name, direction: .download)
        row.total = file.size
        row.state = .active
        transfers.append(row)
        let rowID = row.id

        let isDir = file.looksLikeDirectory
        let remote = file.path

        let onProgress: (Int64, Int64) -> Bool = { [weak self] done, total in
            progress.completedUnitCount = done
            if total > 0 { progress.totalUnitCount = total }
            DispatchQueue.main.async {
                guard let self, let idx = self.transfers.firstIndex(where: { $0.id == rowID }) else { return }
                self.transfers[idx].bytes = done
                if total > 0 { self.transfers[idx].total = total }
            }
            return !progress.isCancelled
        }

        transferConnection.perform({ client -> URL in
            if isDir {
                var plan: [(String, Int64, URL)] = []
                try Session.walkRemoteTree(client: client, remote: remote, local: target, into: &plan)
                for (source, size, local) in plan {
                    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try client.download(remote: source, to: local, size: size, progress: onProgress)
                }
            } else {
                try client.download(remote: remote, to: target, size: file.size, progress: onProgress)
            }
            return target
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if let idx = self.transfers.firstIndex(where: { $0.id == rowID }) {
                    switch result {
                    case .success:
                        self.transfers[idx].state = .done
                        self.transfers[idx].bytes = self.transfers[idx].total
                    case .failure(let error):
                        self.transfers[idx].state = .failed(error.localizedDescription)
                    }
                }
                completion(result)
            }
        })
    }
}
