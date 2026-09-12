import Foundation
import Synchronization
import Translation

/// Exercises the settings/request boundary using isolated preferences, an
/// in-memory credential store, and controlled local/cloud completions.
@MainActor
enum TranslationModelTests {
    static func run() async -> Bool {
        let suite = Suite()

        await suite.run("existing preference keys restore all provider models") {
            let legacy: [String: Any] = [
                "translationProvider": "dashScope", "dashScopeRegion": "unitedStates",
                "dashScopeModel": "saved-qwen", "translationModel.openAI": "saved-gpt",
                "translationModel.deepSeek": "saved-deepseek", "translationModel.gemini": "saved-gemini",
                "translationModel.claude": "saved-claude",
            ]
            try await withModel(legacy) { model, _, _ in
                try expect(model.provider == .dashScope && model.dashScopeRegion == .unitedStates,
                           "saved provider or region was lost")
                for (provider, expected) in [
                    (TranslationProvider.dashScope, "saved-qwen"), (.openAI, "saved-gpt"),
                    (.deepSeek, "saved-deepseek"), (.gemini, "saved-gemini"), (.claude, "saved-claude"),
                ] {
                    model.provider = provider
                    try expect(model.selectedModel == expected, "saved model lost for \(provider)")
                }
            }
        }

        await suite.run("category selection remembers each category independently") {
            try await withModel([
                "lastTranslationAPIProvider": "deepL", "lastLanguageModelProvider": "gemini",
            ]) { model, _, _ in
                model.selectCategory(.translationAPIs)
                try expect(model.provider == .deepL, "saved translation API was not selected")
                model.selectCategory(.languageModels)
                try expect(model.provider == .gemini, "saved language model provider was not selected")
                model.provider = .deepSeek
                model.selectCategory(.disabled)
                model.selectCategory(.languageModels)
                try expect(model.provider == .deepSeek, "language model selection was not remembered")
                model.selectCategory(.translationAPIs)
                try expect(model.provider == .deepL, "switching language models overwrote the API choice")
            }
            try await withModel([
                "lastTranslationAPIProvider": "openAI", "lastLanguageModelProvider": "deepL",
            ]) { model, _, _ in
                model.selectCategory(.translationAPIs)
                try expect(model.provider == .googleCloud, "invalid API category memory was accepted")
                model.selectCategory(.languageModels)
                try expect(model.provider == .openAI, "invalid model category memory was accepted")
            }
        }

        await suite.run("one model binding persists a separate value for each provider") {
            try await withModel(["translationProvider": "openAI"]) { model, settings, _ in
                model.selectedModel = "custom-openai"
                model.provider = .deepSeek
                try expect(model.selectedModel == TranslationProvider.deepSeek.recommendedModel,
                           "a new provider inherited another provider's model")
                model.selectedModel = "custom-deepseek"
                model.provider = .dashScope
                model.selectedModel = "custom-qwen"
                model.provider = .openAI
                try expect(model.selectedModel == "custom-openai", "switching providers discarded the model")
                try expect(settings.string(forKey: "translationModel.openAI") == "custom-openai",
                           "OpenAI storage key changed")
                try expect(settings.string(forKey: "translationModel.deepSeek") == "custom-deepseek",
                           "DeepSeek model was not persisted")
                try expect(settings.string(forKey: "dashScopeModel") == "custom-qwen",
                           "legacy DashScope storage key changed")
            }
        }

        await suite.run("region changes update standard DashScope models and preserve custom models") {
            try await withModel(["translationProvider": "dashScope"]) { model, _, _ in
                model.dashScopeRegion = .unitedStates
                try expect(model.selectedModel == DashScopeRegion.unitedStates.recommendedModel,
                           "standard model did not follow the region")
                model.selectedModel = "qwen-plus"
                model.dashScopeRegion = .international
                try expect(model.selectedModel == DashScopeRegion.international.recommendedModel,
                           "legacy standard model did not follow the region")
                model.selectedModel = "my-private-deployment"
                model.provider = .openAI
                model.dashScopeRegion = .china
                model.provider = .dashScope
                try expect(model.selectedModel == "my-private-deployment", "region change overwrote a custom model")
            }
        }

        await suite.run("restoring defaults preserves credentials") {
            try await withModel([
                "translationProvider": "dashScope", "dashScopeRegion": "unitedStates",
                "dashScopeModel": "custom", "translationModel.openAI": "custom-openai",
                "lastTranslationAPIProvider": "deepL", "lastLanguageModelProvider": "dashScope",
            ]) { model, settings, keys in
                let savedKeys = keys.values
                model.restoreDefaults()
                try expect(model.provider == .apple && model.dashScopeRegion == .china, "default selection not restored")
                for key in ["dashScopeModel", "translationModel.openAI", "lastTranslationAPIProvider", "lastLanguageModelProvider"] {
                    try expect(settings.object(forKey: key) == nil, "old preference \(key) survived reset")
                }
                try expect(keys.values == savedKeys && keys.writes == 0, "restoring preferences changed credentials")
                model.provider = .dashScope
                try expect(model.selectedModel == DashScopeRegion.china.recommendedModel, "custom model survived reset")
                try expect(model.hasAPIKey, "saved key was unavailable after restoring defaults")
            }
        }

        await suite.run("credential read and write failures remain visible") {
            let keys = Keys()
            keys.readFailure = Fault("read denied")
            try await withModel(["translationProvider": "openAI"], keys: keys) { model, _, _ in
                try expectFailure(model.status, containing: "read denied")
                do {
                    _ = try await model.translate("Some text.")
                    throw Fault("credential read failure was swallowed")
                } catch let error as Fault {
                    try expect(error.message == "read denied", "read failure was replaced with a missing-key error")
                }
                try expectFailure(model.status, containing: "read denied")
                try expect(ModelHTTP.requests.isEmpty, "failed credential read made an HTTP request")
            }
            keys.readFailure = nil
            keys.writeFailure = Fault("write denied")
            try await withModel(["translationProvider": "openAI"], keys: keys) { model, _, _ in
                let savedKey = keys.values[.openAI]
                try expect(!model.saveAPIKey("replacement"), "failed save reported success")
                try expectFailure(model.status, containing: "write denied")
                try expect(model.hasAPIKey && keys.values[.openAI] == savedKey, "failed save discarded the existing key")
                model.removeAPIKey()
                try expectFailure(model.status, containing: "write denied")
                try expect(model.hasAPIKey && keys.values[.openAI] == savedKey, "failed removal discarded the existing key")
            }
        }

        await suite.run("two dictionary requests can complete independently") {
            let apple = ControlledApple()
            defer { apple.finishRemaining() }
            try await withModel(apple: apple.service) { model, _, _ in
                let first = Task { try await model.translate("First passage.\n翻译成中文。") }
                let second = Task { try await model.translate("Second passage.\n翻译成中文。") }
                defer { first.cancel(); second.cancel() }
                try await eventually("both dictionary requests started") { apple.sources.count == 2 }
                let firstIndex = apple.sources.firstIndex(of: "First passage.")!
                let secondIndex = apple.sources.firstIndex(of: "Second passage.")!
                apple.finish(secondIndex, with: .success("second translation"))
                let secondText = try await second.value
                try expect(secondText == "second translation", "second frame got the wrong result")
                apple.finish(firstIndex, with: .success("first translation"))
                let firstText = try await first.value
                try expect(firstText == "first translation", "first frame was cancelled by the second")
                try expect(model.status == .idle, "dictionary requests changed the Settings status")
            }
        }

        await suite.run("dictionary results and errors do not replace Settings test status") {
            let apple = ControlledApple()
            defer { apple.finishRemaining() }
            try await withModel(apple: apple.service) { model, _, _ in
                model.testTranslation()
                try await eventually("settings test started") { apple.sources.count == 1 }
                let dictionary = Task { try await model.translate("Dictionary passage.") }
                defer { dictionary.cancel() }
                try await eventually("dictionary request started") { apple.sources.count == 2 }
                apple.finish(1, with: .success("dictionary result"))
                _ = try await dictionary.value
                try expect(model.status == .testing, "dictionary completion replaced the pending Settings test")
                apple.finish(0, with: .success("settings result"))
                try await eventually("settings result published") { model.status == .success("settings result") }

                let failingDictionary = Task { try await model.translate("Another passage.") }
                defer { failingDictionary.cancel() }
                try await eventually("failing dictionary request started") { apple.sources.count == 3 }
                apple.finish(2, with: .failure(Fault("dictionary error")))
                do {
                    _ = try await failingDictionary.value
                    throw Fault("dictionary error was swallowed")
                } catch let error as Fault {
                    try expect(error.message == "dictionary error", "wrong dictionary error")
                }
                try expect(model.status == .success("settings result"), "dictionary failure changed Settings status")

                let pendingDictionary = Task { try await model.translate("Still reading this passage.") }
                defer { pendingDictionary.cancel() }
                try await eventually("dictionary request began before Settings test") { apple.sources.count == 4 }
                model.testTranslation()
                try await eventually("new Settings test began") { apple.sources.count == 5 }
                apple.finish(4, with: .success("new settings result"))
                try await eventually("new Settings test finished") { model.status == .success("new settings result") }
                apple.finish(3, with: .success("pending dictionary result"))
                let pendingResult = try await pendingDictionary.value
                try expect(pendingResult == "pending dictionary result", "Settings test cancelled a dictionary request")
                try expect(model.status == .success("new settings result"), "older dictionary result changed Settings status")
            }
        }

        await suite.run("a cancelled Settings completion cannot overwrite a newer result") {
            let apple = ControlledApple()
            defer { apple.finishRemaining() }
            try await withModel(apple: apple.service) { model, _, _ in
                model.testTranslation()
                try await eventually("old test started") { apple.sources.count == 1 }
                model.provider = .disabled
                try expect(model.status == .idle, "changing provider did not clear the old test")
                model.provider = .apple
                model.testTranslation()
                try await eventually("new test started") { apple.sources.count == 2 }
                apple.finish(1, with: .success("new translation"))
                try await eventually("new test finished") { model.status == .success("new translation") }
                // The injected operation deliberately ignores cancellation and
                // completes late, like an already-running system translation.
                apple.finish(0, with: .success("obsolete translation"))
                try await eventually("old operation returned") { apple.returned.contains(0) }
                await Task.yield()
                try expect(model.status == .success("new translation"), "late result overwrote the new test")
            }
        }

        for change in ["provider", "model", "region", "save credential", "remove credential"] {
            await suite.run("changing \(change) cancels an in-flight cloud Settings test") {
                try await withModel(["translationProvider": "dashScope"]) { model, _, keys in
                    model.testTranslation()
                    try await eventually("cloud test started") { ModelHTTP.requests.count == 1 }
                    let oldRequest = ModelHTTP.requests[0].id
                    switch change {
                    case "provider": model.provider = .openAI
                    case "model": model.selectedModel = "another-model"
                    case "region": model.dashScopeRegion = .international
                    case "save credential": try expect(model.saveAPIKey("replacement-key"), "credential save failed")
                    default: model.removeAPIKey()
                    }
                    let expectedStatus = model.status
                    try expect(expectedStatus != .testing, "settings change left the obsolete test active")
                    try await eventually("obsolete HTTP request stopped") { ModelHTTP.stopped.contains(oldRequest) }
                    await Task.yield()
                    try expect(model.status == expectedStatus, "cancelled request overwrote the settings action's status")

                    keys.values[model.provider] = "new-request-key"
                    model.testTranslation()
                    try await eventually("replacement cloud test started") { ModelHTTP.requests.count == 2 }
                    ModelHTTP.complete(ModelHTTP.requests[1].id, text: "fresh translation")
                    try await eventually("replacement test succeeded") { model.status == .success("fresh translation") }
                }
            }
        }

        await suite.run("dictionary requests retain their submitted configuration when Settings change") {
            try await withModel([
                "translationProvider": "dashScope", "dashScopeRegion": "international", "dashScopeModel": "original-model",
            ]) { model, _, keys in
                let dictionary = Task { try await model.translate("Original passage.") }
                defer { dictionary.cancel() }
                try await eventually("dictionary HTTP request started") { ModelHTTP.requests.count == 1 }
                let submitted = ModelHTTP.requests[0]
                model.dashScopeRegion = .unitedStates
                model.selectedModel = "new-model"
                model.provider = .openAI
                _ = model.saveAPIKey("another-key")
                try expect(submitted.request.url?.host == "dashscope-intl.aliyuncs.com", "request used the new region")
                try expect(submitted.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(keys.values[.dashScope]!)",
                           "request used another provider's credentials")
                let body = try jsonBody(submitted.request)
                try expect(body["model"] as? String == "original-model", "request used the new model")
                ModelHTTP.complete(submitted.id, text: "original request result")
                let result = try await dictionary.value
                try expect(result == "original request result", "editing Settings cancelled a dictionary request")
            }
        }

        return suite.finish()
    }

    private static func withModel(
        _ initial: [String: Any] = [:], keys: Keys? = nil, apple: AppleTranslationService? = nil,
        _ body: @MainActor (TranslationModel, UserDefaults, Keys) async throws -> Void
    ) async throws {
        let name = "Lexicon.TranslationModelTests.\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: name)!
        settings.setPersistentDomain(initial, forName: name)
        let keys = keys ?? Keys()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelHTTP.self]
        let session = URLSession(configuration: configuration)
        ModelHTTP.reset()
        let model = TranslationModel(
            settings: settings,
            apple: apple ?? AppleTranslationService(
                availability: { .installed }, translateInstalled: { _ in throw Fault("unexpected Apple request") }
            ),
            credentials: keys.credentials, session: session
        )
        defer {
            model.cancelTest()
            session.invalidateAndCancel()
            settings.removePersistentDomain(forName: name)
        }
        try await body(model, settings, keys)
    }

    private static func eventually(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Fault("timed out: \(description)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Fault(message) }
    }

    private static func expectFailure(_ status: TranslationModel.Status, containing text: String) throws {
        guard case .failure(let message) = status, message.contains(text) else {
            throw Fault("missing visible failure containing \(text): \(status)")
        }
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? Fault("request stream failed") }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Fault("request body was not a JSON object")
        }
        return body
    }

    private struct Fault: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @MainActor
    private final class Keys {
        var values = Dictionary(uniqueKeysWithValues: TranslationProvider.allCases.filter(\.requiresAPIKey)
            .map { ($0, "test-key-" + $0.rawValue) })
        var readFailure: Fault?
        var writeFailure: Fault?
        var writes = 0

        var credentials: TranslationModel.Credentials {
            TranslationModel.Credentials(
                read: { provider in
                    if let error = self.readFailure { throw error }
                    return self.values[provider]
                },
                save: { provider, key in
                    if let error = self.writeFailure { throw error }
                    self.writes += 1
                    self.values[provider] = key
                },
                remove: { provider in
                    if let error = self.writeFailure { throw error }
                    self.writes += 1
                    self.values.removeValue(forKey: provider)
                }
            )
        }
    }

    @MainActor
    private final class ControlledApple {
        var sources: [String] = []
        var returned = Set<Int>()
        private var continuations: [Int: CheckedContinuation<String, Error>] = [:]

        var service: AppleTranslationService {
            AppleTranslationService(availability: { .installed }, translateInstalled: { source in
                let index = self.sources.count
                self.sources.append(source)
                let result = try await withCheckedThrowingContinuation { self.continuations[index] = $0 }
                self.returned.insert(index)
                return result
            })
        }

        func finish(_ index: Int, with result: Result<String, Error>) {
            continuations.removeValue(forKey: index)?.resume(with: result)
        }

        func finishRemaining() {
            let pending = continuations.values
            continuations.removeAll()
            for continuation in pending { continuation.resume(throwing: CancellationError()) }
        }
    }

    @MainActor
    private final class Suite {
        private var passed = 0
        private var failures = 0
        func run(_ name: String, _ body: @MainActor () async throws -> Void) async {
            do { try await body(); passed += 1 }
            catch {
                failures += 1
                print("TRANSLATION MODEL FAIL [\(name)]: \(error)")
            }
        }
        func finish() -> Bool {
            print("TRANSLATION MODEL \(failures == 0 ? "OK" : "FAILED"): \(passed) passed, \(failures) failed")
            return failures == 0
        }
    }
}

private final class ModelHTTP: URLProtocol, @unchecked Sendable {
    struct Submitted: Sendable {
        let id: UUID
        let request: URLRequest
    }
    private struct State: Sendable {
        var requests: [Submitted] = []
        var pending: [UUID: ModelHTTP] = [:]
        var stopped = Set<UUID>()
    }
    private static let state = Mutex(State())
    private let id = UUID()
    static var requests: [Submitted] { state.withLock { $0.requests } }
    static var stopped: Set<UUID> { state.withLock { $0.stopped } }
    static func reset() { state.withLock { $0 = State() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.withLock {
            $0.requests.append(Submitted(id: id, request: request))
            $0.pending[id] = self
        }
    }
    override func stopLoading() {
        Self.state.withLock {
            $0.stopped.insert(id)
            $0.pending.removeValue(forKey: id)
        }
    }
    static func complete(_ id: UUID, text: String) {
        guard let pending = state.withLock({ $0.pending.removeValue(forKey: id) }) else { return }
        let object: [String: Any]
        if pending.request.url?.host == "api.openai.com" {
            object = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
        } else {
            object = ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
        }
        let response = HTTPURLResponse(url: pending.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        pending.client?.urlProtocol(pending, didReceive: response, cacheStoragePolicy: .notAllowed)
        pending.client?.urlProtocol(pending, didLoad: try! JSONSerialization.data(withJSONObject: object))
        pending.client?.urlProtocolDidFinishLoading(pending)
    }
}
