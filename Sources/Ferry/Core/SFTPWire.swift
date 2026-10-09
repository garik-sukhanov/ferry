import Foundation

/// SFTP protocol version 3 wire format (draft-ietf-secsh-filexfer-02).
enum FXP: UInt8 {
    case initPacket = 1, version = 2, open = 3, close = 4, read = 5, write = 6
    case lstat = 7, fstat = 8, setstat = 9, fsetstat = 10
    case opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15
    case realpath = 16, stat = 17, rename = 18, readlink = 19, symlink = 20
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
}

enum FXStatus: UInt32 {
    case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4
    case badMessage = 5, noConnection = 6, connectionLost = 7, opUnsupported = 8

    var message: String {
        switch self {
        case .ok:               return "OK"
        case .eof:              return "Конец файла"
        case .noSuchFile:       return "Файл или папка не найдены"
        case .permissionDenied: return "Отказано в доступе"
        case .failure:          return "Операция не удалась"
        case .badMessage:       return "Некорректный пакет"
        case .noConnection:     return "Нет соединения"
        case .connectionLost:   return "Соединение потеряно"
        case .opUnsupported:    return "Операция не поддерживается сервером"
        }
    }
}

struct SFTPOpenFlags {
    static let read: UInt32   = 0x0000_0001
    static let write: UInt32  = 0x0000_0002
    static let append: UInt32 = 0x0000_0004
    static let creat: UInt32  = 0x0000_0008
    static let trunc: UInt32  = 0x0000_0010
    static let excl: UInt32   = 0x0000_0020
}

struct SFTPAttrs {
    var size: Int64?
    var permissions: UInt32?
    var mtime: Date?

    var isDirectory: Bool { (permissions.map { $0 & 0o170000 } ?? 0) == 0o040000 }
    var isSymlink: Bool { (permissions.map { $0 & 0o170000 } ?? 0) == 0o120000 }
}

/// Big-endian builder for outgoing packets.
struct SFTPWriter {
    private(set) var bytes = Data()

    mutating func byte(_ v: UInt8) { bytes.append(v) }

    mutating func uint32(_ v: UInt32) {
        var b = v.bigEndian
        withUnsafeBytes(of: &b) { bytes.append(contentsOf: $0) }
    }

    mutating func uint64(_ v: UInt64) {
        var b = v.bigEndian
        withUnsafeBytes(of: &b) { bytes.append(contentsOf: $0) }
    }

    mutating func string(_ s: String) {
        let d = Data(s.utf8)
        uint32(UInt32(d.count))
        bytes.append(d)
    }

    mutating func blob(_ d: Data) {
        uint32(UInt32(d.count))
        bytes.append(d)
    }

    /// Wrap payload in the `length | type | body` envelope.
    func framed(type: FXP, requestID: UInt32?) -> Data {
        var body = Data()
        body.append(type.rawValue)
        if let requestID {
            var be = requestID.bigEndian
            withUnsafeBytes(of: &be) { body.append(contentsOf: $0) }
        }
        body.append(bytes)

        var out = Data()
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}

/// Big-endian reader for incoming packets.
struct SFTPReader {
    private let data: Data
    private var pos: Int

    init(_ data: Data) {
        self.data = data
        self.pos = data.startIndex
    }

    var remaining: Int { data.endIndex - pos }

    mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw FerryError.protocolError("Пакет обрезан") }
        defer { pos += 1 }
        return data[pos]
    }

    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw FerryError.protocolError("Пакет обрезан") }
        defer { pos += 4 }
        return data[pos..<pos+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 {
        guard remaining >= 8 else { throw FerryError.protocolError("Пакет обрезан") }
        defer { pos += 8 }
        return data[pos..<pos+8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func blob() throws -> Data {
        let n = Int(try uint32())
        guard remaining >= n else { throw FerryError.protocolError("Пакет обрезан") }
        defer { pos += n }
        return data[pos..<pos+n]
    }

    mutating func string() throws -> String {
        let d = try blob()
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    mutating func attrs() throws -> SFTPAttrs {
        var a = SFTPAttrs()
        let flags = try uint32()
        if flags & 0x1 != 0 { a.size = Int64(bitPattern: try uint64()) }
        if flags & 0x2 != 0 { _ = try uint32(); _ = try uint32() }      // uid, gid
        if flags & 0x4 != 0 { a.permissions = try uint32() }
        if flags & 0x8 != 0 {
            _ = try uint32()                                            // atime
            a.mtime = Date(timeIntervalSince1970: TimeInterval(try uint32()))
        }
        if flags & 0x8000_0000 != 0 {
            let count = try uint32()
            for _ in 0..<count { _ = try blob(); _ = try blob() }
        }
        return a
    }
}
