import Foundation
import Combine

@MainActor
public final class TranscriptSelection: ObservableObject {
    public enum State {
        case idle, loading, loaded(TranscriptDocument), failed(String)
    }
    @Published public private(set) var state: State = .idle
    private let loader: @Sendable (String, Bool) async throws -> TranscriptDocument
    private var task: Task<Void, Never>?
    private var token = UUID()

    public init(reader: TranscriptReader) { loader = { try await reader.load(transcriptPath: $0, force: $1) } }
    public init(loader: @escaping @Sendable (String, Bool) async throws -> TranscriptDocument) { self.loader = loader }
    public func select(path: String?, force: Bool = false) {
        task?.cancel(); token = UUID()
        guard let path else { state = .idle; return }
        state = .loading
        let current = token, load = loader
        task = Task { [weak self] in
            do {
                let doc = try await load(path, force)
                guard !Task.isCancelled, let self, self.token == current else { return }
                self.state = .loaded(doc)
            } catch {
                guard !Task.isCancelled, let self, self.token == current else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }
    public func cancel() { task?.cancel(); token = UUID() }
}
