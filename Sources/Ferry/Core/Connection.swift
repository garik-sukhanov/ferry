import Foundation

func makeClient(_ profile: ServerProfile) -> RemoteFS {
    switch profile.proto {
    case .sftp:        return SFTPClient(profile: profile)
    case .ftp, .ftps:  return FTPClient(profile: profile)
    }
}

/// Owns one transport on its own serial queue. The client object is only ever
/// touched from that queue, so callers never need locks. Dropped connections
/// are re-established on the next call.
final class Connection {
    private let profile: ServerProfile
    private let password: String?
    private let queue: DispatchQueue
    private var client: RemoteFS?

    init(profile: ServerProfile, password: String?, label: String) {
        self.profile = profile
        self.password = password
        self.queue = DispatchQueue(label: "me.garik.Ferry.\(label)", qos: .userInitiated)
    }

    func perform<T>(_ body: @escaping (RemoteFS) throws -> T,
                    then: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            do {
                let client = try self.ensureClient()
                then(.success(try body(client)))
            } catch {
                if Self.isFatal(error) {
                    self.client?.disconnect()
                    self.client = nil
                }
                then(.failure(error))
            }
        }
    }

    private func ensureClient() throws -> RemoteFS {
        if let client { return client }
        let fresh = makeClient(profile)
        try fresh.connect(password: password)
        client = fresh
        return fresh
    }

    /// Only connection-level failures invalidate the session; "file not found"
    /// must not tear down a perfectly good control channel.
    private static func isFatal(_ error: Error) -> Bool {
        guard let e = error as? FerryError else { return false }
        switch e {
        case .transport, .notConnected, .auth: return true
        default:                               return false
        }
    }

    func close() {
        queue.async {
            self.client?.disconnect()
            self.client = nil
        }
    }
}
