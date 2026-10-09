import XCTest
@testable import Ferry

/// End-to-end tests against the docker servers started by Tools/test_servers.sh.
/// They are skipped automatically when the ports are closed.
final class LiveServerTests: XCTestCase {

    private func sftpProfile() -> ServerProfile {
        var p = ServerProfile()
        p.host = "127.0.0.1"
        p.port = 2222
        p.username = "tester"
        p.proto = .sftp
        p.auth = .password
        p.remotePath = "/share"
        return p
    }

    private func ftpProfile() -> ServerProfile {
        var p = ServerProfile()
        p.host = "127.0.0.1"
        p.port = 2121
        p.username = "tester"
        p.proto = .ftp
        p.auth = .password
        return p
    }

    private func portOpen(_ port: UInt16) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        task.arguments = ["-z", "-G", "2", "127.0.0.1", String(port)]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private func makeScratchFile(bytes: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ferry-test-\(UUID().uuidString).bin")
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<bytes { base[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
        }
        try data.write(to: url)
        return url
    }

    /// Full round trip: connect → mkdir → upload → list → download → verify
    /// → rename → delete.
    private func runRoundTrip(client: RemoteFS, password: String) throws {
        try client.connect(password: password)
        defer { client.disconnect() }

        // The server decides where we land; paths are built from there.
        let base = try client.currentDirectory()
        XCTAssertTrue(base.hasPrefix("/"), "стартовый путь должен быть абсолютным: \(base)")

        let dirName = "ferry-test-\(Int(Date().timeIntervalSince1970))"
        let dir = remoteJoin(base, dirName)
        try client.makeDirectory(dir)

        let payloadSize = 1_500_000            // spans many protocol chunks
        let localSource = try makeScratchFile(bytes: payloadSize)
        defer { try? FileManager.default.removeItem(at: localSource) }

        let remoteFile = remoteJoin(dir, "payload.bin")
        var uploadTicks = 0
        try client.upload(local: localSource, to: remoteFile) { _, _ in uploadTicks += 1; return true }
        XCTAssertGreaterThan(uploadTicks, 0, "прогресс выгрузки не вызывался")

        let listing = try client.list(dir)
        XCTAssertEqual(listing.count, 1)
        XCTAssertEqual(listing.first?.name, "payload.bin")
        XCTAssertEqual(listing.first?.size, Int64(payloadSize), "размер на сервере не совпал")

        let localTarget = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ferry-down-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: localTarget) }
        try client.download(remote: remoteFile, to: localTarget,
                            size: Int64(payloadSize)) { _, _ in true }

        let original = try Data(contentsOf: localSource)
        let roundTripped = try Data(contentsOf: localTarget)
        XCTAssertEqual(roundTripped.count, original.count, "размер скачанного файла не совпал")
        XCTAssertEqual(roundTripped, original, "содержимое файла испорчено при передаче")

        let renamed = remoteJoin(dir, "renamed.bin")
        try client.rename(remoteFile, to: renamed)
        let afterRename = try client.list(dir)
        XCTAssertEqual(afterRename.first?.name, "renamed.bin")

        try client.delete(dir, isDirectory: true)
        let parent = try client.list(base)
        XCTAssertFalse(parent.contains { $0.name == dirName }, "папка не удалена")
    }

    func testSFTPRoundTrip() throws {
        try XCTSkipUnless(portOpen(2222), "SFTP-сервер не запущен")
        let client = SFTPClient(profile: sftpProfile())
        try runRoundTrip(client: client, password: "secret123")
    }

    func testFTPRoundTrip() throws {
        try XCTSkipUnless(portOpen(2121), "FTP-сервер не запущен")
        let client = FTPClient(profile: ftpProfile())
        try runRoundTrip(client: client, password: "secret123")
    }

    func testSFTPWrongPasswordFails() throws {
        try XCTSkipUnless(portOpen(2222), "SFTP-сервер не запущен")
        let client = SFTPClient(profile: sftpProfile())
        XCTAssertThrowsError(try client.connect(password: "definitely-wrong"))
        client.disconnect()
    }

    func testSFTPCancelStopsDownload() throws {
        try XCTSkipUnless(portOpen(2222), "SFTP-сервер не запущен")
        let client = SFTPClient(profile: sftpProfile())
        try client.connect(password: "secret123")
        defer { client.disconnect() }

        let dir = "/share"
        let source = try makeScratchFile(bytes: 4_000_000)
        defer { try? FileManager.default.removeItem(at: source) }
        let remote = remoteJoin(dir, "cancel-me.bin")
        try client.upload(local: source, to: remote) { _, _ in true }
        defer { try? client.delete(remote, isDirectory: false) }

        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ferry-cancel-\(UUID().uuidString).bin")
        XCTAssertThrowsError(
            try client.download(remote: remote, to: target, size: 4_000_000) { done, _ in
                done < 200_000                       // pull the plug early
            }
        ) { error in
            guard case FerryError.cancelled = error else {
                return XCTFail("ожидалась отмена, получено: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "частично скачанный файл должен удаляться")

        // The session must still be usable after a cancel.
        XCTAssertNoThrow(try client.list(dir))
    }

    func testRemotePathHelpers() {
        XCTAssertEqual(remoteJoin("/var/www", "index.php"), "/var/www/index.php")
        XCTAssertEqual(remoteJoin("/", "a"), "/a")
        XCTAssertEqual(remoteJoin("/x/", "y"), "/x/y")
        XCTAssertEqual(remoteParent("/var/www/index.php"), "/var/www")
        XCTAssertEqual(remoteParent("/var"), "/")
        XCTAssertEqual(remoteParent("/"), "/")
    }
}
