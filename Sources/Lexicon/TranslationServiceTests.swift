import Foundation
import Synchronization

/// Offline regression coverage for the app's translation adapters. Every HTTP
/// request is intercepted, including unexpected hosts; no API keys are read.
@MainActor
enum TranslationServiceTests {
    private static let prompt = "The first sentence.\nThe second sentence.\n"
        + "Translate the English sentences above into Simplified Chinese."
    private static let source = "The first sentence.\nThe second sentence."

    static func run() async -> Bool {
        let suite = Suite()

        await suite.run("provider metadata and region routing") {
            let grouped = TranslationProviderCategory.allCases.flatMap {
                TranslationProvider.providers(in: $0)
            }
            try expect(Set(grouped) == Set(TranslationProvider.allCases), "missing provider category")
            try expect(grouped.count == TranslationProvider.allCases.count, "duplicate provider category")
            for provider in TranslationProvider.allCases {
                try expect(
                    provider.requiresAPIKey == (provider != .apple && provider != .disabled),
                    "incorrect key requirement for \(provider)"
                )
                if provider.isGeneralLanguageModel && provider != .dashScope {
                    try expect(provider.recommendedModel?.isEmpty == false, "missing model default")
                }
            }
            try expect(
                DictionaryTranslationService.deepLEndpoint(forAPIKey: "test:fx").host == "api-free.deepl.com",
                "DeepL Free routing failed"
            )
            try expect(
                DictionaryTranslationService.deepLEndpoint(forAPIKey: "test").host == "api.deepl.com",
                "DeepL Pro routing failed"
            )
        }

        await suite.run("source passage extraction") {
            let cases: [(String, String)] = [
                ("", ""), (" \n\t", ""),
                ("One line.", "One line."),
                (" First.\n\n Second. ", "First.\nSecond."),
                (prompt, source),
                ("First.\nSecond.\n将上面的英文翻译为简体中文。\n请保留标记。", "First.\nSecond."),
                ("请将以下英文翻译成中文。\r\nFirst.\r\nSecond.", "First.\nSecond."),
                ("Translate the following into Chinese.\nFirst.\nSecond.", "First.\nSecond."),
                ("Translate the following into Chinese.", ""),
                ("请将以下英文翻译成中文。", ""),
            ]
            for (input, expected) in cases {
                try expect(
                    DictionaryTranslationService.sourcePassage(from: input) == expected,
                    "wrong extracted source for \(input.debugDescription)"
                )
            }
            try expect(
                DictionaryTranslationService.plainSourcePassage(
                    from: "<M>First</M> <n>note</n> <o>other</o> ⋖ 5.\n翻译成中文。"
                ) == "First note other < 5.",
                "Apple source did not strip dictionary markers"
            )
        }

        await suite.run("translation input validates once without dropping instructions") {
            let input = try TranslationInput(" \n" + prompt + "\t ")
            try expect(input.prompt == prompt, "input lost part of the full prompt")
            let boundary = try TranslationInput(String(repeating: "a", count: 20_000))
            try expect(boundary.prompt.utf8.count == 20_000, "valid input size boundary rejected")
            for provider in TranslationProvider.allCases.filter(\.requiresAPIKey) {
                try await expectError(provider, prompt: " \n ", fixture: .failure(.cannotConnectToHost),
                                      contains: "no text", expectedRequestCount: 0)
                try await expectError(provider, prompt: String(repeating: "译", count: 6_667),
                                      fixture: .failure(.cannotConnectToHost),
                                      contains: "too long", expectedRequestCount: 0)
                try await expectError(provider, apiKey: " \t ", fixture: .failure(.cannotConnectToHost),
                                      contains: "API key", expectedRequestCount: 0)
            }
        }

        for markup in [false, true] {
            await suite.run("Google request and response (markup: \(markup))") {
                let text = markup ? "<m>A <n>note</n></m>" : source
                let result = try await call(
                    .googleCloud, prompt: text + "\n翻译成中文。",
                    fixture: .json(#"{"data":{"translations":[{"translatedText":"<m>译文</m>"}]}}"#)
                ) { request in
                    try expect(request.url?.host == "translation.googleapis.com", "wrong Google host")
                    try expect(request.url?.query == nil, "Google key leaked into URL")
                    try expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key", "wrong Google key header")
                    let body = try jsonBody(request)
                    try expect(body["q"] as? [String] == [text], "Google did not receive source only")
                    try expect(body["source"] as? String == "en", "wrong Google source")
                    try expect(body["target"] as? String == "zh-CN", "wrong Google target")
                    try expect(body["format"] as? String == (markup ? "html" : "text"), "wrong Google format")
                }
                try expect(result == "<m>译文</m>", "Google lost translated markup")
            }
        }

        for markup in [false, true] {
            await suite.run("DeepL request and response (markup: \(markup))") {
                let text = markup ? "<m>A <n>note</n></m>" : source
                let input = markup ? text + "\n翻译成中文。" : text
                let result = try await call(
                    .deepL, prompt: input, apiKey: "test-key:fx",
                    fixture: .json(#"{"translations":[{"text":"<m>译文</m>"}]}"#)
                ) { request in
                    try expect(request.url?.host == "api-free.deepl.com", "wrong DeepL host")
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key test-key:fx", "wrong DeepL authorization")
                    let body = try jsonBody(request)
                    try expect(body["text"] as? [String] == [text], "DeepL source changed")
                    try expect(body["source_lang"] as? String == "EN", "wrong DeepL source")
                    try expect(body["target_lang"] as? String == "ZH-HANS", "wrong DeepL target")
                    try expect(body["context"] as? String == (markup ? input : nil), "wrong DeepL context")
                    try expect(body["tag_handling"] as? String == (markup ? "html" : nil), "wrong tag handling")
                    try expect(body["tag_handling_version"] as? String == (markup ? "v2" : nil), "wrong tag version")
                    try expect(body["ignore_tags"] as? [String] == (markup ? ["n", "o"] : nil), "wrong ignored tags")
                }
                try expect(result == "<m>译文</m>", "DeepL lost translated markup")
            }
        }

        await suite.run("OpenAI Responses request and content selection") {
            let result = try await call(.openAI, fixture: .json(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"  译"},{"type":"output_text","text":"文  "}]}]}"#)) { request in
                try expect(request.url?.absoluteString == "https://api.openai.com/v1/responses", "wrong OpenAI endpoint")
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "wrong OpenAI authorization")
                let body = try jsonBody(request)
                try expect(body["model"] as? String == "test-model", "model was not trimmed")
                try expect(body["input"] as? String == prompt, "OpenAI prompt changed")
                try expect(body["store"] as? Bool == false, "OpenAI unexpectedly stores requests")
                try expect((body["instructions"] as? String)?.contains("preserve") == true, "missing translation instruction")
            }
            try expect(result == "译文", "OpenAI included non-text output")
        }

        for provider in [TranslationProvider.deepSeek, .gemini] {
            await suite.run("\(provider.title) compatible chat request and response") {
                let result = try await call(provider, fixture: .json(chatJSON)) { request in
                    let host = provider == .deepSeek ? "api.deepseek.com" : "generativelanguage.googleapis.com"
                    try expect(request.url?.host == host, "wrong compatible-chat endpoint")
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "wrong chat authorization")
                    let body = try jsonBody(request)
                    try expect(body["model"] as? String == "test-model", "chat model was not trimmed")
                    try expect(body["stream"] as? Bool == false, "unexpected chat stream")
                    try expect(body["enable_thinking"] == nil && body["temperature"] == nil,
                               "DashScope-specific options leaked into compatible chat")
                    let messages = body["messages"] as? [[String: String]]
                    try expect(messages?.map { $0["role"] ?? "" } == ["system", "user"], "missing chat roles")
                    try expect(messages?.last?["content"] == prompt, "chat prompt changed")
                }
                try expect(result == "译文", "chat did not select and trim first choice")
            }
        }

        await suite.run("Claude Messages request and content selection") {
            let result = try await call(.claude, fixture: .json(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"ignored"},{"type":"text","text":"  译"},{"type":"text","text":"文  "}]}"#)) { request in
                try expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages", "wrong Claude endpoint")
                try expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key", "wrong Claude key header")
                try expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "missing Claude API version")
                let body = try jsonBody(request)
                try expect(body["model"] as? String == "test-model", "Claude model was not trimmed")
                try expect(body["max_tokens"] as? Int == 8_192, "missing Claude token budget")
                let messages = body["messages"] as? [[String: String]]
                try expect(messages == [["role": "user", "content": prompt]], "Claude prompt changed")
            }
            try expect(result == "译文", "Claude included non-text content")
        }

        for region in DashScopeRegion.allCases {
            await suite.run("DashScope \(region.rawValue) routing and options") {
                let result = try await call(.dashScope, model: " dash-model \n", region: region, fixture: .json(chatJSON)) { request in
                    let hosts: [DashScopeRegion: String] = [
                        .china: "dashscope.aliyuncs.com",
                        .international: "dashscope-intl.aliyuncs.com",
                        .unitedStates: "dashscope-us.aliyuncs.com",
                    ]
                    try expect(request.url?.host == hosts[region], "wrong DashScope region")
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "wrong DashScope authorization")
                    let body = try jsonBody(request)
                    try expect(body["model"] as? String == "dash-model", "DashScope model was not trimmed")
                    try expect(body["stream"] as? Bool == false, "unexpected DashScope stream")
                    try expect(body["enable_thinking"] as? Bool == false, "DashScope thinking not disabled")
                    try expect(body["temperature"] as? Double == 0.1, "wrong DashScope temperature")
                    let messages = body["messages"] as? [[String: String]]
                    try expect(messages == [["role": "user", "content": prompt]], "DashScope prompt changed")
                }
                try expect(result == "译文", "DashScope did not trim output")
            }
        }

        for provider in TranslationProvider.allCases.filter(\.requiresAPIKey) {
            let emptyResponse: String
            switch provider {
            case .googleCloud: emptyResponse = #"{"data":{"translations":[]}}"#
            case .deepL: emptyResponse = #"{"translations":[{"text":"  \n "}]}"#
            case .openAI: emptyResponse = #"{"status":"completed","output":[]}"#
            case .claude: emptyResponse = #"{"stop_reason":"end_turn","content":[]}"#
            default: emptyResponse = #"{"choices":[{"finish_reason":"stop","message":{"content":null}}]}"#
            }
            await suite.run("\(provider.title) empty translation") {
                try await expectError(provider, fixture: .json(emptyResponse), contains: "empty translation")
            }
            await suite.run("\(provider.title) malformed success response") {
                do {
                    _ = try await call(provider, fixture: .json("not json"))
                    throw Failure(message: "malformed response was accepted")
                } catch is DecodingError { }
            }
            await suite.run("\(provider.title) HTTP error message") {
                try await expectError(
                    provider, fixture: .json(#"{"error":{"message":"Quota exhausted"}}"#, status: 429),
                    contains: "Quota exhausted"
                )
            }
        }

        await suite.run("HTTP error fallbacks and invalid response") {
            try await expectError(.deepL, fixture: .json(#"{"message":"Invalid authentication key"}"#, status: 403), contains: "Invalid authentication key")
            try await expectError(.googleCloud, fixture: .json("<html>bad gateway</html>", status: 502), contains: "HTTP 502")
            try await expectError(.openAI, fixture: .json(#"{"error":{"message":"  "}}"#, status: 500), contains: "HTTP 500")
            try await expectError(.deepSeek, fixture: .nonHTTP, contains: "invalid response")
        }

        await suite.run("transport failures and cancellation preserve error codes") {
            for code in [URLError.Code.notConnectedToInternet, .timedOut, .cancelled] {
                do {
                    _ = try await call(.googleCloud, fixture: .failure(code))
                    throw Failure(message: "transport error was swallowed")
                } catch let error as URLError {
                    try expect(error.code == code, "transport error code changed")
                }
            }
        }

        await suite.run("cancelled task does not start an HTTP request") {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await call(.googleCloud, fixture: .failure(.cannotConnectToHost))
            }
            do {
                _ = try await task.value
                throw Failure(message: "cancelled task was accepted")
            } catch is CancellationError {
                try expect(TranslationMockProtocol.requests.isEmpty, "cancelled task sent an HTTP request")
            }
        }

        await suite.run("dedicated translation APIs preserve returned markup whitespace") {
            let translation = " \n<m>译文</m>\t "
            for provider in [TranslationProvider.googleCloud, .deepL] {
                let response: [String: Any] = provider == .googleCloud
                    ? ["data": ["translations": [["translatedText": translation]]]]
                    : ["translations": [["text": translation]]]
                let json = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
                let result = try await call(provider, apiKey: " test-key ", fixture: .json(json)) { request in
                    let key = provider == .googleCloud
                        ? request.value(forHTTPHeaderField: "x-goog-api-key")
                        : request.value(forHTTPHeaderField: "Authorization")
                    try expect(key == (provider == .googleCloud ? "test-key" : "DeepL-Auth-Key test-key"),
                               "key was not normalized before building headers")
                }
                try expect(result == translation, "dedicated API output whitespace changed")
            }
        }

        await suite.run("incomplete language-model responses are rejected") {
            for status in ["incomplete", "failed", "cancelled", "in_progress", "queued"] {
                let json = "{\"status\":\"\(status)\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial\"}]}]}"
                try await expectError(.openAI, fixture: .json(json), contains: "did not finish")
            }
            for reason in ["max_tokens", "model_context_window_exceeded", "refusal", "pause_turn", "tool_use"] {
                let json = "{\"stop_reason\":\"\(reason)\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}"
                try await expectError(.claude, fixture: .json(json), contains: "did not finish")
            }
            for provider in [TranslationProvider.deepSeek, .gemini, .dashScope] {
                for reason in ["length", "content_filter", "tool_calls", "insufficient_system_resource"] {
                    let json = "{\"choices\":[{\"finish_reason\":\"\(reason)\",\"message\":{\"content\":\"partial\"}}]}"
                    try await expectError(provider, fixture: .json(json), contains: "did not finish")
                }
            }
        }

        await suite.run("invalid provider, source and model fail without HTTP") {
            for provider in [TranslationProvider.apple, .disabled] {
                try await expectError(provider, fixture: .failure(.cannotConnectToHost), contains: provider == .apple ? "system translation session" : "Choose a live", expectedRequestCount: 0)
            }
            for provider in [TranslationProvider.googleCloud, .deepL] {
                for source in [" \n ", "请将以下英文翻译成中文。"] {
                    try await expectError(provider, prompt: source, fixture: .failure(.cannotConnectToHost), contains: "no text", expectedRequestCount: 0)
                }
            }
            for provider in TranslationProvider.allCases.filter(\.isGeneralLanguageModel) {
                try await expectError(provider, model: " \n ", fixture: .failure(.cannotConnectToHost), contains: "model name", expectedRequestCount: 0)
            }
        }

        return suite.finish()
    }

    private static let chatJSON = #"{"choices":[{"finish_reason":"stop","message":{"content":"  译文  "}},{"finish_reason":"stop","message":{"content":"ignored"}}]}"#

    private static func call(
        _ provider: TranslationProvider,
        prompt input: String = prompt,
        apiKey: String = "test-key",
        model: String = " test-model \n",
        region: DashScopeRegion = .china,
        fixture: TranslationMockProtocol.Fixture,
        inspect: (URLRequest) throws -> Void = { _ in }
    ) async throws -> String {
        TranslationMockProtocol.prepare(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = try await DictionaryTranslationService.translate(
            input: try TranslationInput(input),
            configuration: TranslationConfiguration(provider: provider, model: model, dashScopeRegion: region),
            apiKey: apiKey, session: session
        )
        let requests = TranslationMockProtocol.requests
        try expect(requests.count == 1, "expected exactly one request")
        let request = requests[0]
        try expect(request.httpMethod == "POST", "request is not POST")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8", "wrong content type")
        let expectedTimeout: TimeInterval = provider.category == .translationAPIs ? 30 : provider == .dashScope ? 45 : 60
        try expect(request.timeoutInterval == expectedTimeout, "provider timeout changed")
        try inspect(request)
        return result
    }

    private static func expectError(
        _ provider: TranslationProvider,
        prompt input: String = prompt,
        apiKey: String = "test-key",
        model: String = "test-model",
        fixture: TranslationMockProtocol.Fixture,
        contains fragment: String,
        expectedRequestCount: Int = 1
    ) async throws {
        do {
            _ = try await call(provider, prompt: input, apiKey: apiKey, model: model, fixture: fixture)
            throw Failure(message: "expected error containing \(fragment)")
        } catch let error as TranslationServiceError {
            try expect(error.message.contains(fragment), "wrong error: \(error.message)")
            try expect(TranslationMockProtocol.requests.count == expectedRequestCount, "unexpected network request count")
        }
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? Failure(message: "body stream failed") }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            data = body
        } else {
            throw Failure(message: "missing request body")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "request body is not a JSON object")
        }
        return object
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private struct Failure: Error { let message: String }

    @MainActor
    private final class Suite {
        var passed = 0
        var failures = 0

        func run(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                passed += 1
            } catch {
                failures += 1
                print("TRANSLATION SERVICE FAIL [\(name)]: \(error)")
            }
        }

        func finish() -> Bool {
            print("TRANSLATION SERVICE \(failures == 0 ? "OK" : "FAILED"): \(passed) passed, \(failures) failed")
            return failures == 0
        }
    }
}

private final class TranslationMockProtocol: URLProtocol, @unchecked Sendable {
    enum Fixture: Sendable {
        case json(String, status: Int = 200)
        case nonHTTP
        case failure(URLError.Code)
    }

    private struct State: Sendable {
        var fixture: Fixture = .failure(.unsupportedURL)
        var requests: [URLRequest] = []
    }

    private static let state = Mutex(State())

    static var requests: [URLRequest] { state.withLock { $0.requests } }

    static func prepare(_ fixture: Fixture) {
        state.withLock { $0 = State(fixture: fixture) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.state.withLock {
            $0.requests.append(request)
            return $0.fixture
        }
        switch fixture {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .nonHTTP:
            let response = URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .json(let json, let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { }
}
