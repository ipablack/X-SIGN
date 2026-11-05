import Foundation

// One operation owns its temporary files until it returns; stopping never interrupts native Zsign.
@MainActor
final class XSignBatchQueue<Item> {
    enum State: Equatable {
        case waiting, working, succeeded(String), failed(String), cancelled
        var isRetryable: Bool {
            switch self { case .failed, .cancelled: return true; default: return false }
        }
    }
    struct Entry: Identifiable {
        let id = UUID()
        let item: Item
        var state: State = .waiting
    }
    private(set) var entries: [Entry]
    private(set) var isRunning = false
    var onChange: (() -> Void)?
    private var task: Task<Void, Never>?
    private var stopRequested = false

    init(items: [Item]) { entries = items.map { Entry(item: $0) } }

    func start(operation: @escaping @MainActor (Item) async throws -> String) {
        guard !isRunning, entries.contains(where: { $0.state == .waiting }) else { return }
        isRunning = true
        stopRequested = false
        onChange?()
        task = Task { @MainActor in
            for index in self.entries.indices {
                guard !self.stopRequested else { break }
                guard self.entries[index].state == .waiting else { continue }
                self.entries[index].state = .working
                self.onChange?()
                do { self.entries[index].state = .succeeded(try await operation(self.entries[index].item)) }
                catch { self.entries[index].state = .failed(error.localizedDescription) }
                self.onChange?()
            }
            self.isRunning = false
            self.task = nil
            self.onChange?()
        }
    }

    func stopAfterCurrent() {
        stopRequested = true
        for index in entries.indices where entries[index].state == .waiting { entries[index].state = .cancelled }
        onChange?()
    }

    func prepareRetry() {
        guard !isRunning else { return }
        for index in entries.indices where entries[index].state.isRetryable { entries[index].state = .waiting }
        onChange?()
    }
}
