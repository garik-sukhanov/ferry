import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var session: Session
    let profile: ServerProfile
    @EnvironmentObject var state: AppState

    @State private var selection = Set<RemoteFile.ID>()
    @State private var filter = ""
    @State private var renaming: RemoteFile?
    @State private var renameText = ""
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @State private var sortOrder = [KeyPathComparator(\RemoteFile.name)]

    private var visibleFiles: [RemoteFile] {
        guard !filter.isEmpty else { return session.files }
        return session.files.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var selectedFiles: [RemoteFile] {
        session.files.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
            TransfersBar(session: session)
        }
        .navigationTitle(profile.displayName)
        .navigationSubtitle(session.path)
        .toolbar { toolbarItems }
        .searchable(text: $filter, placement: .toolbar, prompt: "Фильтр")
        .onChange(of: session.path) { selection.removeAll() }
        .sheet(item: $renaming) { file in
            PromptSheet(title: "Переименовать", label: file.name,
                        text: $renameText, confirm: "Переименовать") {
                session.rename(file, to: renameText)
            }
        }
        .sheet(isPresented: $creatingFolder) {
            PromptSheet(title: "Новая папка", label: session.path,
                        text: $folderName, confirm: "Создать") {
                session.makeDirectory(named: folderName)
            }
        }
        .confirmationDialog("Удалить \(pluralizeObjects(selectedFiles.count)) без возможности восстановления?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                session.delete(selectedFiles)
                selection.removeAll()
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: - Pieces

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button { session.goUp() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(session.path == "/")
                .help("Наверх (⌘↑)")

            ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(crumb.label) { session.navigate(to: crumb.path) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(index == breadcrumbs.count - 1 ? Color.primary : Color.secondary)
            }
            Spacer()
            if session.loading { ProgressView().controlSize(.small) }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var breadcrumbs: [(label: String, path: String)] {
        var out: [(String, String)] = [("/", "/")]
        var acc = ""
        for part in session.path.split(separator: "/") {
            acc += "/" + part
            out.append((String(part), acc))
        }
        return out
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                Text("Подключение к \(profile.host)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.orange)
                Text("Не удалось подключиться").font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
                HStack {
                    Button("Повторить") { session.connect() }
                    Button("Настройки сервера…") { state.edit(profile) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

        case .connected:
            fileTable
                .overlay(alignment: .top) { banner }
        }
    }

    private var fileTable: some View {
        Table(of: RemoteFile.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Имя", value: \.name) { file in
                HStack(spacing: 6) {
                    Image(systemName: iconName(file))
                        .foregroundStyle(file.looksLikeDirectory ? Color.accentColor : Color.secondary)
                    Text(file.name).lineLimit(1)
                }
            }
            .width(min: 220, ideal: 380)

            TableColumn("Размер", value: \.size) { file in
                Text(file.looksLikeDirectory ? "—" : formatBytes(file.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(90)

            TableColumn("Изменён") { file in
                Text(file.modified.map { Self.dateFormatter.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(160)

            TableColumn("Права") { file in
                Text(file.permissions)
                    .foregroundStyle(.tertiary)
                    .monospaced()
            }
            .width(100)
        } rows: {
            ForEach(visibleFiles) { file in
                TableRow(file)
                    .itemProvider { DragProvider.provider(for: file, session: session) }
            }
        }
        .onChange(of: sortOrder) { session.files.sort(using: sortOrder) }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            open(ids)
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.upload(urls, to: session.path)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<RemoteFile.ID>) -> some View {
        let files = session.files.filter { ids.contains($0.id) }
        if files.isEmpty {
            Button("Новая папка…") { folderName = ""; creatingFolder = true }
            Button("Обновить") { session.reload() }
        } else {
            if files.count == 1, files[0].looksLikeDirectory {
                Button("Открыть") { open(ids) }
            }
            Button("Скачать в «\(session.downloadFolder.lastPathComponent)»") {
                session.download(files, to: session.downloadFolder)
            }
            Button("Скачать в…") { chooseFolderAndDownload(files) }
            Divider()
            if files.count == 1 {
                Button("Переименовать…") {
                    renameText = files[0].name
                    renaming = files[0]
                }
                Button("Копировать путь") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(files[0].path, forType: .string)
                }
            }
            Divider()
            Button("Удалить", role: .destructive) { selection = ids; confirmDelete = true }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let message = session.banner {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white)
                Text(message).foregroundStyle(.white).lineLimit(2)
                Spacer()
                Button {
                    session.banner = nil
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.white)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Обновить (⌘R)")
                .accessibilityLabel("Обновить")

            Button { folderName = ""; creatingFolder = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Новая папка")
            .accessibilityLabel("Новая папка")

            Button { chooseFilesAndUpload() } label: {
                Image(systemName: "arrow.up.doc")
            }
            .help("Загрузить файлы на сервер")
            .accessibilityLabel("Загрузить на сервер")

            Button {
                session.download(selectedFiles, to: session.downloadFolder)
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .disabled(selection.isEmpty)
            .help("Скачать выбранное")
            .accessibilityLabel("Скачать выбранное")

            Button { confirmDelete = true } label: {
                Image(systemName: "trash")
            }
            .disabled(selection.isEmpty)
            .help("Удалить выбранное")
            .accessibilityLabel("Удалить выбранное")
        }
    }

    // MARK: - Actions

    private func open(_ ids: Set<RemoteFile.ID>) {
        let files = session.files.filter { ids.contains($0.id) }
        guard let first = files.first else { return }
        if first.looksLikeDirectory {
            session.navigate(to: first.path)
        } else {
            session.download(files, to: session.downloadFolder)
        }
    }

    private func chooseFilesAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Загрузить"
        if panel.runModal() == .OK {
            session.upload(panel.urls, to: session.path)
        }
    }

    private func chooseFolderAndDownload(_ files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Сохранить"
        if panel.runModal() == .OK, let url = panel.url {
            session.download(files, to: url)
        }
    }

    private func iconName(_ file: RemoteFile) -> String {
        if file.kind == .symlink { return "arrow.triangle.turn.up.right.circle" }
        if file.looksLikeDirectory { return "folder.fill" }
        switch (file.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": return "photo"
        case "zip", "gz", "tar", "bz2", "xz", "7z", "rar":       return "doc.zipper"
        case "mp4", "mov", "mkv", "avi", "webm":                 return "film"
        case "mp3", "wav", "flac", "aac", "m4a":                 return "waveform"
        case "pdf":                                              return "doc.richtext"
        case "php", "js", "ts", "py", "rb", "go", "swift", "sh": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "xml", "toml", "ini", "env": return "curlybraces"
        case "sql", "db", "sqlite":                              return "cylinder"
        default:                                                 return "doc"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Small sheet used for both rename and "new folder".
struct PromptSheet: View {
    let title: String
    let label: String
    @Binding var text: String
    let confirm: String
    let action: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            TextField("Имя", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        action()
        dismiss()
    }
}
