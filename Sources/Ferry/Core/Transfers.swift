import Foundation

struct Transfer: Identifiable {
    enum Direction { case download, upload }
    enum State: Equatable {
        case waiting, active, done, cancelled
        case failed(String)
    }

    let id = UUID()
    var name: String
    var direction: Direction
    var bytes: Int64 = 0
    var total: Int64 = 0
    var state: State = .waiting
    var speed: Double = 0            // bytes per second

    var fraction: Double {
        total > 0 ? min(1, Double(bytes) / Double(total)) : 0
    }

    var isFinished: Bool {
        switch state {
        case .done, .cancelled, .failed: return true
        case .waiting, .active:          return false
        }
    }
}

/// Work item handed to the transfer thread.
struct TransferJob {
    enum Payload {
        case download(remote: String, size: Int64, local: URL)
        case upload(local: URL, remote: String)
        case makeRemoteDirectory(String)
        case makeLocalDirectory(URL)
    }
    var id: UUID
    var payload: Payload
}

func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    return f.string(fromByteCount: n)
}

/// "1 объект", "2 объекта", "5 объектов".
func pluralizeObjects(_ n: Int) -> String {
    let mod100 = n % 100
    let mod10 = n % 10
    if (11...14).contains(mod100) { return "\(n) объектов" }
    switch mod10 {
    case 1:      return "\(n) объект"
    case 2...4:  return "\(n) объекта"
    default:     return "\(n) объектов"
    }
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 1 else { return "" }
    return formatBytes(Int64(bytesPerSecond)) + "/с"
}
