import Foundation

/// Profiles live in a plain JSON file; secrets never touch it — they go to the
/// Keychain and are looked up by profile id.
@MainActor
final class ServerStore: ObservableObject {
    @Published var servers: [ServerProfile] = []

    private let url: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ferry", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("servers.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ServerProfile].self, from: data) else { return }
        servers = list
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(servers) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func upsert(_ profile: ServerProfile, password: String?) {
        if let idx = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[idx] = profile
        } else {
            servers.append(profile)
        }
        if let password, profile.savePassword, !password.isEmpty {
            Keychain.save(password, account: profile.keychainAccount)
        } else if !profile.savePassword {
            Keychain.delete(account: profile.keychainAccount)
        }
        persist()
    }

    func remove(_ profile: ServerProfile) {
        servers.removeAll { $0.id == profile.id }
        Keychain.delete(account: profile.keychainAccount)
        persist()
    }

    func password(for profile: ServerProfile) -> String? {
        Keychain.load(account: profile.keychainAccount)
    }
}
