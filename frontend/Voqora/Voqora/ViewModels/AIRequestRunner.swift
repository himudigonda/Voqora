import Foundation

nonisolated enum AIRequestState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(AIReadingError)

    var value: Value? {
        if case let .loaded(value) = self {
            return value
        }
        return nil
    }

    var error: AIReadingError? {
        if case let .failed(error) = self {
            return error
        }
        return nil
    }

    var isLoading: Bool {
        self == .loading
    }
}

@MainActor
final class AIRequestRunner {
    private var task: Task<Void, Never>?
    private var generation = 0

    var isRunning: Bool {
        task != nil
    }

    func run<Value>(
        _ operation: @escaping @MainActor () async throws -> Value,
        completion: @escaping @MainActor (Result<Value, AIReadingError>) -> Void
    ) {
        cancel()
        let current = generation
        task = Task { [weak self] in
            let result: Result<Value, AIReadingError>
            do {
                result = try await .success(operation())
            } catch is CancellationError {
                return
            } catch {
                result = .failure(AIReadingError.wrapping(error))
            }
            guard let self, current == generation, !Task.isCancelled else { return }
            task = nil
            completion(result)
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
