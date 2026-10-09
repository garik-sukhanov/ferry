import XCTest
import UniformTypeIdentifiers
@testable import Ferry

/// Exercises the path Finder takes when a row is dragged out of the window:
/// the item provider must fetch the file on demand and hand back a real URL.
final class DragOutTests: XCTestCase {

    private var keyPath: String {
        URL(fileURLWithPath: #filePath)            // …/Tests/FerryTests/DragOutTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".testdata/ferry_key")
            .path
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

    @MainActor
    func testDragProviderFetchesFileOnDemand() throws {
        try XCTSkipUnless(portOpen(2222), "SFTP-сервер не запущен")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: keyPath),
                          "нет тестового ключа — запустите Tools/test_servers.sh up")

        var profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = 2222
        profile.username = "tester"
        profile.proto = .sftp
        profile.auth = .keyFile
        profile.privateKeyPath = keyPath
        profile.remotePath = "/share"

        let session = Session(profile: profile, password: nil)
        let file = RemoteFile(name: "readme.txt", path: "/share/readme.txt",
                              kind: .file, size: 22, modified: nil, permissions: "")

        let provider = DragProvider.provider(for: file, session: session)
        let type = provider.registeredTypeIdentifiers.first
        XCTAssertNotNil(type, "провайдер не зарегистрировал тип")

        let done = expectation(description: "файл выгружен для Finder")
        var fetched: Data?
        var failure: Error?

        provider.loadFileRepresentation(forTypeIdentifier: type!) { url, error in
            // The URL is only valid inside this callback, so copy right away —
            // exactly what Finder does on drop.
            if let url { fetched = try? Data(contentsOf: url) }
            failure = error
            done.fulfill()
        }

        wait(for: [done], timeout: 30)
        XCTAssertNil(failure, "выгрузка завершилась ошибкой: \(String(describing: failure))")
        XCTAssertEqual(fetched.map { String(decoding: $0, as: UTF8.self) },
                       "hello from ferry test\n",
                       "перетащенный файл пришёл с неверным содержимым")

        // The transfer should be visible in the UI list, not silently done.
        XCTAssertTrue(session.transfers.contains { $0.name == "readme.txt" },
                      "перетаскивание не попало в список передач")
        session.close()
    }
}
