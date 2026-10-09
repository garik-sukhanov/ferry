import SwiftUI

struct ServerEditorView: View {
    @State var profile: ServerProfile
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.isNewServer ? "Новый сервер" : "Настройки сервера")
                .font(.headline)
                .padding(16)

            Divider()

            Form {
                Section {
                    TextField("Название", text: $profile.name, prompt: Text("Мой хостинг"))
                    Picker("Протокол", selection: $profile.proto) {
                        ForEach(TransferProtocol.allCases) { p in Text(p.title).tag(p) }
                    }
                    .onChange(of: profile.proto) { _, new in
                        profile.port = new.defaultPort
                        if new != .sftp, profile.auth != .password { profile.auth = .password }
                    }
                }

                Section {
                    TextField("Сервер", text: $profile.host, prompt: Text("example.com"))
                    TextField("Порт", value: $profile.port, format: .number.grouping(.never))
                    TextField("Пользователь", text: $profile.username)
                }

                Section {
                    if profile.proto == .sftp {
                        Picker("Вход", selection: $profile.auth) {
                            ForEach(AuthMethod.allCases) { m in Text(m.title).tag(m) }
                        }
                    }

                    switch profile.auth {
                    case .password:
                        SecureField("Пароль", text: $state.editingPassword)
                        Toggle("Сохранить пароль в Связке ключей", isOn: $profile.savePassword)
                    case .keyFile:
                        HStack {
                            TextField("Файл ключа", text: $profile.privateKeyPath,
                                      prompt: Text("~/.ssh/id_ed25519"))
                            Button("Выбрать…") { pickKey() }
                        }
                    case .agent:
                        Text("Будут использованы ключи из ~/.ssh и ssh-agent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Папка на сервере", text: $profile.remotePath,
                              prompt: Text("по умолчанию"))
                    HStack {
                        TextField("Папка загрузок", text: $profile.localPath,
                                  prompt: Text("~/Downloads"))
                        Button("Выбрать…") { pickLocalFolder() }
                    }
                    if profile.proto != .sftp {
                        Toggle("Пассивный режим (PASV)", isOn: $profile.passive)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Проверить") { test() }
                    .disabled(profile.host.isEmpty || testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testOK ? .green : .red)
                        .font(.caption)
                        .lineLimit(2)
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    state.saveEditing(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.host.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
    }

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            profile.privateKeyPath = url.path
        }
    }

    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            profile.localPath = url.path
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let snapshot = profile
        let password = state.editingPassword

        DispatchQueue.global(qos: .userInitiated).async {
            let client = makeClient(snapshot)
            var message = ""
            var ok = false
            do {
                try client.connect(password: password)
                let dir = try client.currentDirectory()
                _ = try client.list(dir)
                message = "Подключение успешно · \(dir)"
                ok = true
            } catch {
                message = error.localizedDescription
            }
            client.disconnect()

            DispatchQueue.main.async {
                testing = false
                testOK = ok
                testResult = message
            }
        }
    }
}
