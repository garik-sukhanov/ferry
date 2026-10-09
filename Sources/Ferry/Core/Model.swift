import Foundation

enum TransferProtocol: String, Codable, CaseIterable, Identifiable {
    case sftp
    case ftp
    case ftps          // explicit TLS over port 21 (AUTH TLS)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sftp: return "SFTP (SSH)"
        case .ftp:  return "FTP"
        case .ftps: return "FTPS (TLS)"
        }
    }

    var defaultPort: Int {
        switch self {
        case .sftp: return 22
        case .ftp, .ftps: return 21
        }
    }
}

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case keyFile       // SFTP only: private key on disk
    case agent         // SFTP only: ssh-agent / ~/.ssh defaults

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "Пароль"
        case .keyFile:  return "Ключ (файл)"
        case .agent:    return "ssh-agent / ~/.ssh"
        }
    }
}

struct ServerProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var proto: TransferProtocol = .sftp
    var auth: AuthMethod = .password
    var privateKeyPath: String = ""
    var remotePath: String = ""          // start directory, empty = server default
    var localPath: String = ""           // preferred download folder
    var passive: Bool = true             // FTP only
    var savePassword: Bool = true

    /// Key under which the secret lives in the Keychain.
    var keychainAccount: String { "\(id.uuidString)" }

    var displayName: String {
        if !name.isEmpty { return name }
        if host.isEmpty { return "Новый сервер" }
        return "\(username.isEmpty ? "" : username + "@")\(host)"
    }

    var subtitle: String {
        let p = port == proto.defaultPort ? "" : ":\(port)"
        return "\(proto.rawValue.uppercased()) · \(host)\(p)"
    }
}

struct RemoteFile: Identifiable, Hashable {
    enum Kind: Hashable {
        case directory
        case file
        case symlink
        case other
    }

    var name: String
    var path: String                    // absolute remote path
    var kind: Kind
    var size: Int64
    var modified: Date?
    var permissions: String             // "rwxr-xr-x" or ""

    var id: String { path }

    var isDirectory: Bool { kind == .directory }

    /// Symlinks are resolved lazily; treat unknown links as folders when they
    /// have no extension, which is the common case for remote deployments.
    var looksLikeDirectory: Bool {
        kind == .directory || (kind == .symlink && (name as NSString).pathExtension.isEmpty)
    }
}

enum FerryError: LocalizedError {
    case notConnected
    case protocolError(String)
    case auth(String)
    case transport(String)
    case cancelled
    case local(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:            return "Нет подключения к серверу"
        case .protocolError(let m):    return m
        case .auth(let m):             return "Ошибка авторизации: \(m)"
        case .transport(let m):        return m
        case .cancelled:               return "Отменено"
        case .local(let m):            return m
        }
    }
}

/// Everything a transport must be able to do. Implementations are synchronous
/// and always run off the main thread — the session actor serialises calls.
protocol RemoteFS: AnyObject {
    func connect(password: String?) throws
    func disconnect()

    func list(_ path: String) throws -> [RemoteFile]
    func currentDirectory() throws -> String

    func download(remote: String, to local: URL, size: Int64, progress: (Int64, Int64) -> Bool) throws
    func upload(local: URL, to remote: String, progress: (Int64, Int64) -> Bool) throws

    func rename(_ from: String, to: String) throws
    func delete(_ path: String, isDirectory: Bool) throws
    func makeDirectory(_ path: String) throws
}

/// Join remote path components with POSIX semantics regardless of the local FS.
func remoteJoin(_ base: String, _ component: String) -> String {
    if component.hasPrefix("/") { return component }
    if base.isEmpty || base == "/" { return "/" + component }
    return base.hasSuffix("/") ? base + component : base + "/" + component
}

func remoteParent(_ path: String) -> String {
    guard path != "/", !path.isEmpty else { return "/" }
    var p = path
    if p.hasSuffix("/") { p.removeLast() }
    guard let idx = p.lastIndex(of: "/") else { return "/" }
    let parent = String(p[p.startIndex..<idx])
    return parent.isEmpty ? "/" : parent
}
