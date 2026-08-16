import Foundation
import MdxKit
// WebKit predates Swift concurrency annotations, so WKURLSchemeTask is not
// Sendable even though WebKit only ever hands it to us on the main thread.
// This applies to Apple's types only; MdxKit is checked strictly.
@preconcurrency import WebKit

/// Serves dict:// URLs from the dictionary library.
///
/// URL layout. Each dictionary is a separate origin:
///   dict://<dictUUID>/entry?word=<normalized key>   entry HTML
///   dict://<dictUUID>/<resource path>               image/CSS/audio/…
///
/// Requests are served off the main thread: building an entry page decompresses
/// record blocks and queries SQLite, and an entry with a dozen images would
/// otherwise run all of that inline on the main thread while the UI waits.
final class DictSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "dict"

    /// `DictionaryLibrary` is thread-safe, so the worker queue may use it
    /// directly. `LibraryModel` is main-actor state and must not be touched
    /// from the queue, which is why only the library is captured.
    private nonisolated let library: DictionaryLibrary?
    private nonisolated let queue = DispatchQueue(
        label: "lexicon.dict-scheme", qos: .userInitiated, attributes: .concurrent
    )
    @MainActor var allowHTTPS: Bool

    /// Tasks WebKit has started and not yet stopped. Calling back into a
    /// stopped task raises an Objective-C exception, so every delivery looks
    /// the task up here first.
    ///
    /// `WKURLSchemeTask` is not `Sendable`: it is stored, read and completed
    /// only on the main thread, and the worker queue carries just a token.
    @MainActor private var liveTasks: [ObjectIdentifier: WKURLSchemeTask] = [:]

    @MainActor
    init(libraryModel: LibraryModel) {
        self.library = libraryModel.library
        self.allowHTTPS = libraryModel.dictionaryNetworkPolicy == .allowHTTPS
    }

    // WKURLSchemeHandler's conformance is main-actor isolated, which matches
    // how WebKit calls it. Staying on that isolation means the task is never
    // sent across an isolation boundary — only `token`, `url` and the result
    // travel to and from the worker queue.
    @MainActor
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let token = ObjectIdentifier(urlSchemeTask)
        liveTasks[token] = urlSchemeTask

        guard let url = urlSchemeTask.request.url else {
            deliver(token: token, url: nil, result: nil)
            return
        }

        let library = self.library
        let allowHTTPS = self.allowHTTPS
        queue.async { [weak self] in
            let result = library.flatMap {
                Self.respond(to: url, library: $0, allowHTTPS: allowHTTPS)
            }
            Task { @MainActor in
                self?.deliver(token: token, url: url, result: result)
            }
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        liveTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }

    @MainActor
    private func deliver(
        token: ObjectIdentifier,
        url: URL?,
        result: DictionaryResource?
    ) {
        // Absent means WebKit stopped the task — the frame navigated away
        // while we were reading — so completing it now would raise.
        guard let task = liveTasks.removeValue(forKey: token) else { return }

        guard let result, let url else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url, mimeType: result.mimeType, expectedContentLength: result.data.count,
            textEncodingName: result.textEncodingName
        )
        task.didReceive(response)
        task.didReceive(result.data)
        task.didFinish()
    }

    /// Runs on the worker queue.
    private nonisolated static func respond(
        to url: URL, library: DictionaryLibrary, allowHTTPS: Bool
    ) -> DictionaryResource? {
        guard let uuid = url.host?.lowercased(), uuid != "page",
              library.isKnownDictionaryUUID(uuid)
        else { return nil }
        let components = url.path.split(separator: "/").map(String.init)

        if components == ["entry"] {
            // `url.path` percent-decodes, so this component is attacker
            // reachable from a dictionary's own markup. Only serve UUIDs the
            // library actually knows; anything else cannot address a
            // dictionary and must not reach the page builder.
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let word = query?.queryItems?.first(where: { $0.name == "word" })?.value ?? ""
            let html = EntryPageBuilder.entryDocument(
                for: word, dictionaryUUID: uuid, library: library,
                allowHTTPS: allowHTTPS
            )
            return DictionaryResource(
                data: Data(html.utf8), mimeType: "text/html",
                textEncodingName: "utf-8", resolvedPath: "entry"
            )
        }

        // Everything else is a resource path inside this dictionary.
        let resourcePath = components.joined(separator: "/")
        if !resourcePath.isEmpty,
           let resource = try? library.resource(path: resourcePath, dictionaryUUID: uuid) {
            return resource
        }
        return nil
    }

    nonisolated static func mimeType(forPath path: String) -> String {
        DictionaryLibrary.mimeType(forPath: path)
    }
}
