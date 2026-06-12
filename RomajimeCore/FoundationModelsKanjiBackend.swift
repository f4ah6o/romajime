import Foundation
import FoundationModels

public enum KanjiBackendError: Error {
    case unavailable
}

// Each conversion uses a fresh session: LanguageModelSession keeps a growing
// transcript, so reusing one across commits would bloat the context window.
// prewarm() exists only to trigger the shared model load early.
public final class FoundationModelsKanjiBackend: KanjiConversionBackend, @unchecked Sendable {
    public init() {}

    public func prewarm() {
        guard #available(macOS 26.0, *) else {
            return
        }
        guard let session = makeSession() else {
            return
        }
        session.prewarm()
    }

    public func convertToKanji(_ request: KanjiConversionRequest) async throws -> String {
        guard #available(macOS 26.0, *), let session = makeSession() else {
            throw KanjiBackendError.unavailable
        }
        let response = try await session.respond(to: KanjiPromptBuilder.prompt(for: request))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(macOS 26.0, *)
    private func makeSession() -> LanguageModelSession? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return nil
        }
        return LanguageModelSession(model: model)
    }
}

public enum KanjiConversionRunner {
    public static func run(backend: any KanjiConversionBackend, request: KanjiConversionRequest, timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self, returning: String?.self) { group in
            group.addTask {
                try? await backend.convertToKanji(request)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
