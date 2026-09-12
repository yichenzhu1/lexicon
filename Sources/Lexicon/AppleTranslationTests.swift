import Foundation
import Translation

/// Exercises the installed-language adapter without creating system sessions,
/// downloading language packs, or depending on the Mac's installed languages.
@MainActor
enum AppleTranslationTests {
    private static let source = "The old lighthouse stood on the cliff."

    static func run() async -> Bool {
        let suite = Suite()

        await suite.run("installed languages translate the original source") {
            var availabilityCalls = 0
            var receivedSources: [String] = []
            let service = AppleTranslationService(
                availability: {
                    availabilityCalls += 1
                    return .installed
                },
                translateInstalled: { text in
                    receivedSources.append(text)
                    return "旧灯塔矗立在悬崖上。"
                }
            )
            let result = try await service.translate(source)
            try expect(result == "旧灯塔矗立在悬崖上。", "translated text changed")
            try expect(availabilityCalls == 1, "availability was not checked exactly once")
            try expect(receivedSources == [source], "source changed or translated more than once")
        }

        await suite.run("missing languages do not create a translation session") {
            var translationCalls = 0
            let service = AppleTranslationService(
                availability: { .supported },
                translateInstalled: { _ in
                    translationCalls += 1
                    return "unexpected"
                }
            )
            do {
                _ = try await service.translate(source)
                throw Failure(message: "missing languages were accepted")
            } catch AppleTranslationSetupError.languagesNotInstalled { }
            try expect(translationCalls == 0, "missing languages reached the translation operation")
        }

        await suite.run("unsupported languages do not create a translation session") {
            var translationCalls = 0
            let service = AppleTranslationService(
                availability: { .unsupported },
                translateInstalled: { _ in
                    translationCalls += 1
                    return "unexpected"
                }
            )
            do {
                _ = try await service.translate(source)
                throw Failure(message: "unsupported languages were accepted")
            } catch AppleTranslationSetupError.unsupported { }
            try expect(translationCalls == 0, "unsupported languages reached the translation operation")
        }

        await suite.run("a later request rechecks downloaded languages") {
            var status = LanguageAvailability.Status.supported
            var translationCalls = 0
            let service = AppleTranslationService(
                availability: { status },
                translateInstalled: { _ in
                    translationCalls += 1
                    return "译文"
                }
            )
            do {
                _ = try await service.translate(source)
                throw Failure(message: "missing languages were accepted")
            } catch AppleTranslationSetupError.languagesNotInstalled { }
            status = .installed
            let result = try await service.translate(source)
            try expect(result == "译文", "newly installed languages were not used")
            try expect(translationCalls == 1, "translation did not wait for installed languages")
        }

        await suite.run("languages removed during translation return download guidance") {
            let service = AppleTranslationService(
                availability: { .installed },
                translateInstalled: { _ in throw TranslationError.notInstalled }
            )
            do {
                _ = try await service.translate(source)
                throw Failure(message: "removed languages were accepted")
            } catch AppleTranslationSetupError.languagesNotInstalled { }
        }

        await suite.run("already-cancelled system sessions preserve cancellation") {
            let service = AppleTranslationService(
                availability: { .installed },
                translateInstalled: { _ in throw TranslationError.alreadyCancelled }
            )
            try await expectCancellation(Task { try await service.translate(source) })
        }

        await suite.run("empty and whitespace-only translations fail") {
            for output in ["", " \n\t "] {
                let service = AppleTranslationService(
                    availability: { .installed },
                    translateInstalled: { _ in output }
                )
                do {
                    _ = try await service.translate(source)
                    throw Failure(message: "empty translation was accepted")
                } catch let error as TranslationServiceError {
                    try expect(error.message.contains("empty translation"), "wrong empty-output error")
                }
            }
        }

        await suite.run("unrelated translation errors are preserved") {
            let service = AppleTranslationService(
                availability: { .installed },
                translateInstalled: { _ in throw URLError(.notConnectedToInternet) }
            )
            do {
                _ = try await service.translate(source)
                throw Failure(message: "translation error was swallowed")
            } catch let error as URLError {
                try expect(error.code == .notConnectedToInternet, "translation error code changed")
            }
        }

        await suite.run("cancellation before starting performs no work") {
            var availabilityCalls = 0
            var translationCalls = 0
            let service = AppleTranslationService(
                availability: {
                    availabilityCalls += 1
                    return .installed
                },
                translateInstalled: { _ in
                    translationCalls += 1
                    return "unexpected"
                }
            )
            // This MainActor task cannot run until the current task suspends.
            let request = Task { try await service.translate(source) }
            request.cancel()
            try await expectCancellation(request)
            try expect(availabilityCalls == 0, "cancelled request checked languages")
            try expect(translationCalls == 0, "cancelled request translated text")
        }

        await suite.run("cancellation while checking languages prevents translation") {
            for status in [LanguageAvailability.Status.installed, .supported, .unsupported] {
                let entered = Signal()
                let release = Signal()
                var translationCalls = 0
                let service = AppleTranslationService(
                    availability: {
                        entered.open()
                        await release.wait()
                        return status
                    },
                    translateInstalled: { _ in
                        translationCalls += 1
                        return "unexpected"
                    }
                )
                let request = Task { try await service.translate(source) }
                await entered.wait()
                request.cancel()
                release.open()
                try await expectCancellation(request)
                try expect(translationCalls == 0, "request translated after cancellation during availability")
            }
        }

        await suite.run("cancellation discards a late successful translation") {
            let entered = Signal()
            let release = Signal()
            let service = AppleTranslationService(
                availability: { .installed },
                translateInstalled: { _ in
                    entered.open()
                    // Deliberately ignore cancellation, like a late framework reply.
                    await release.wait()
                    return "late result"
                }
            )
            let request = Task { try await service.translate(source) }
            await entered.wait()
            request.cancel()
            release.open()
            try await expectCancellation(request)
        }

        await suite.run("concurrent requests complete independently") {
            let firstEntered = Signal()
            let releaseFirst = Signal()
            var sources: [String] = []
            var timedOut = false
            let service = AppleTranslationService(
                availability: { .installed },
                translateInstalled: { text in
                    sources.append(text)
                    if text == "first" {
                        firstEntered.open()
                        await releaseFirst.wait()
                    }
                    return "translated \(text)"
                }
            )
            let first = Task { try await service.translate("first") }
            await firstEntered.wait()
            let second = Task { try await service.translate("second") }
            // A regression that serializes requests must fail instead of hanging
            // the harness forever waiting for the first request's release.
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                timedOut = true
                releaseFirst.open()
            }
            let secondResult = await second.result
            watchdog.cancel()
            releaseFirst.open()
            let firstResult = await first.result
            try expect(!timedOut, "second request waited for the first request to finish")
            try expect(try secondResult.get() == "translated second", "second request received the wrong result")
            try expect(try firstResult.get() == "translated first", "first request received the wrong result")
            try expect(sources == ["first", "second"], "requests were lost, reordered, or duplicated")
        }

        return suite.finish()
    }

    private static func expectCancellation(_ request: Task<String, Error>) async throws {
        do {
            _ = try await request.value
            throw Failure(message: "expected CancellationError")
        } catch is CancellationError { }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }

    private struct Failure: Error { let message: String }

    @MainActor
    private final class Signal {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class Suite {
        private var passed = 0
        private var failures = 0

        func run(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                passed += 1
            } catch {
                failures += 1
                print("APPLE TRANSLATION FAIL [\(name)]: \(error)")
            }
        }

        func finish() -> Bool {
            print("APPLE TRANSLATION \(failures == 0 ? "OK" : "FAILED"): \(passed) passed, \(failures) failed")
            return failures == 0
        }
    }
}
