import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            ServerSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            if let profile = state.store.servers.first(where: { $0.id == state.selected }),
               let session = state.currentSession {
                BrowserView(session: session, profile: profile)
                    .id(profile.id)
            } else {
                EmptyStateView()
            }
        }
        .sheet(item: $state.editing) { profile in
            ServerEditorView(profile: profile)
                .environmentObject(state)
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Выберите сервер слева")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Добавить сервер…") { state.newServer() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ServerSidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(
            get: { state.selected },
            set: { id in
                guard let id, let profile = state.store.servers.first(where: { $0.id == id }) else { return }
                state.connect(to: profile)
            })
        ) {
            Section("Серверы") {
                ForEach(state.store.servers) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: profile))
                            .foregroundStyle(state.isConnected(profile.id) ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName).lineLimit(1)
                            Text(profile.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(profile.id)
                    .contextMenu {
                        Button("Подключиться") { state.connect(to: profile) }
                        Button("Настроить…") { state.edit(profile) }
                        if state.isConnected(profile.id) {
                            Button("Отключиться") { state.disconnect(profile.id) }
                        }
                        Divider()
                        Button("Удалить", role: .destructive) { state.remove(profile) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { state.newServer() } label: {
                    Label("Сервер", systemImage: "plus")
                }
                .buttonStyle(.accessoryBar)
                Spacer()
            }
            .padding(8)
        }
    }

    private func icon(for profile: ServerProfile) -> String {
        switch profile.proto {
        case .sftp: return "lock.shield"
        case .ftps: return "lock"
        case .ftp:  return "network"
        }
    }
}
