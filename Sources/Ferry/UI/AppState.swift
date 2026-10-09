import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var store = ServerStore()
    @Published var selected: UUID?
    @Published var editing: ServerProfile?
    @Published var editingPassword: String = ""
    @Published var isNewServer = false

    private var sessions: [UUID: Session] = [:]

    var currentSession: Session? {
        guard let selected else { return nil }
        return sessions[selected]
    }

    func connect(to profile: ServerProfile) {
        selected = profile.id
        if sessions[profile.id] != nil { return }
        let password = profile.auth == .password ? store.password(for: profile) : nil
        let session = Session(profile: profile, password: password)
        sessions[profile.id] = session
        session.connect()
    }

    func disconnect(_ id: UUID) {
        sessions[id]?.close()
        sessions[id] = nil
        if selected == id { selected = nil }
    }

    func isConnected(_ id: UUID) -> Bool { sessions[id] != nil }

    func newServer() {
        var p = ServerProfile()
        p.port = p.proto.defaultPort
        editing = p
        editingPassword = ""
        isNewServer = true
    }

    func edit(_ profile: ServerProfile) {
        editing = profile
        editingPassword = store.password(for: profile) ?? ""
        isNewServer = false
    }

    func saveEditing(_ profile: ServerProfile) {
        store.upsert(profile, password: editingPassword)
        // Settings changed → drop the live session so the next connect re-reads them.
        if sessions[profile.id] != nil { disconnect(profile.id) }
        editing = nil
        editingPassword = ""
    }

    func remove(_ profile: ServerProfile) {
        disconnect(profile.id)
        store.remove(profile)
    }
}
