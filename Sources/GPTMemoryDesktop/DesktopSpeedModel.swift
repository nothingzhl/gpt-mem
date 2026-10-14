import Foundation
import Combine
import GPTSessionKit

private actor DesktopSpeedService {
    let reader: DesktopSpeedReader
    init(root: URL) { reader = DesktopSpeedReader(rootURL: root) }
    func refresh() throws -> DesktopSpeedSnapshot { try reader.read() }
}
@MainActor final class DesktopSpeedModel: ObservableObject {
    @Published private(set) var snapshot = DesktopSpeedSnapshot()
    @Published private(set) var isMonitoring = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    @Published private(set) var updatedAt: Date?
    let root: URL
    private let service: DesktopSpeedService
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(root: URL = CodexSessionRepository.defaultRootURL) { self.root = root; service = DesktopSpeedService(root: root) }
    func start() {
        guard !isMonitoring else { return }
        task?.cancel(); let id = UUID(); generation = id; isMonitoring = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == id else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; isMonitoring = false }
    func refresh() async {
        guard !isRefreshing else { return }
        let id = generation
        isRefreshing = true; defer { isRefreshing = false }
        do {
            let value = try await service.refresh()
            guard generation == id, !Task.isCancelled else { return }
            if snapshot != value { snapshot = value }
            if error != nil { error = nil }
            updatedAt = Date()
        } catch { if generation == id { self.error = error.localizedDescription } }
    }
}
