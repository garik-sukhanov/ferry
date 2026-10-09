import SwiftUI

struct TransfersBar: View {
    @ObservedObject var session: Session
    @State private var expanded = false

    private var active: [Transfer] { session.transfers.filter { !$0.isFinished } }

    var body: some View {
        if !session.transfers.isEmpty {
            VStack(spacing: 0) {
                Divider()
                header
                if expanded {
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(session.transfers.reversed()) { transfer in
                                TransferRow(transfer: transfer) { session.cancel(transfer.id) }
                                Divider().opacity(0.4)
                            }
                        }
                    }
                    .frame(height: 190)
                }
            }
            .background(.bar)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.caption)
                    Text(summary).font(.callout)
                }
            }
            .buttonStyle(.borderless)

            if let current = active.first {
                ProgressView(value: current.fraction)
                    .frame(maxWidth: 220)
                Text(formatSpeed(current.speed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .leading)
            }

            Spacer()

            if session.transfers.contains(where: { $0.isFinished }) {
                Button("Очистить") { session.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var summary: String {
        let running = active.count
        if running == 0 {
            let failed = session.transfers.filter { if case .failed = $0.state { return true }; return false }.count
            return failed > 0 ? "Передачи · ошибок: \(failed)" : "Передачи завершены"
        }
        return "Передача — осталось \(running)"
    }
}

struct TransferRow: View {
    let transfer: Transfer
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).lineLimit(1)
                switch transfer.state {
                case .active:
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .waiting:
                    Text("В очереди").font(.caption).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Отменено").font(.caption).foregroundStyle(.secondary)
                case .done:
                    Text(formatBytes(transfer.total)).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !transfer.isFinished {
                Button { cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var detail: String {
        let done = formatBytes(transfer.bytes)
        let total = transfer.total > 0 ? formatBytes(transfer.total) : "?"
        let speed = formatSpeed(transfer.speed)
        return speed.isEmpty ? "\(done) из \(total)" : "\(done) из \(total) · \(speed)"
    }

    private var icon: String {
        switch transfer.state {
        case .done:      return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        default:         return transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .done:      return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        default:         return .accentColor
        }
    }
}
