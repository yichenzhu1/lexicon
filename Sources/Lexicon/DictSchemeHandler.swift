import Foundation
import MdxKit
// WebKit predates Swift concurrency annotations, so WKURLSchemeTask is not
// Sendable even though WebKit only ever hands it to us on the main thread.
// This applies to Apple's types only; MdxKit is checked strictly.
@preconcurrency import WebKit

/// Serves dict:// URLs from the dictionary library.
///
/// URL layout (host is always "d" so that the outer page and all entry
/// iframes share one origin, letting the outer page measure iframe heights):
///   dict://d/<dictUUID>/entry?word=<normalized key>   entry HTML for one dictionary
///   dict://d/<dictUUID>/<resource path>               image/CSS/audio/… from the MDD
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
    }

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let token = ObjectIdentifier(urlSchemeTask)
        let url = urlSchemeTask.request.url

        // WebKit starts and stops tasks on the main thread, so registering the
        // task is already correctly isolated. The dispatch below must stay
        // outside this closure: a closure formed inside an actor-isolated one
        // inherits that isolation and would assert on the worker queue.
        MainActor.assumeIsolated { liveTasks[token] = urlSchemeTask }

        guard let url else {
            MainActor.assumeIsolated { deliver(token: token, url: nil, result: nil) }
            return
        }

        let library = self.library
        queue.async { [weak self] in
            let result = library.flatMap { Self.respond(to: url, library: $0) }
            Task { @MainActor in
                self?.deliver(token: token, url: url, result: result)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Take the token outside the closure so the task itself is never
        // captured across isolation.
        let token = ObjectIdentifier(urlSchemeTask)
        MainActor.assumeIsolated {
            _ = liveTasks.removeValue(forKey: token)
        }
    }

    @MainActor
    private func deliver(
        token: ObjectIdentifier,
        url: URL?,
        result: (data: Data, mimeType: String)?
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
            textEncodingName: result.mimeType.hasPrefix("text/") ? "utf-8" : nil
        )
        task.didReceive(response)
        task.didReceive(result.data)
        task.didFinish()
    }

    /// Runs on the worker queue.
    private nonisolated static func respond(
        to url: URL, library: DictionaryLibrary
    ) -> (data: Data, mimeType: String)? {
        var components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        let uuid = components.removeFirst()

        if components == ["entry"] {
            // `url.path` percent-decodes, so this component is attacker
            // reachable from a dictionary's own markup. Only serve UUIDs the
            // library actually knows; anything else cannot address a
            // dictionary and must not reach the page builder.
            guard library.isKnownDictionaryUUID(uuid) else { return nil }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let word = query?.queryItems?.first(where: { $0.name == "word" })?.value ?? ""
            let html = EntryPageBuilder.entryDocument(
                for: word, dictionaryUUID: uuid, library: library
            )
            return (Data(html.utf8), "text/html")
        }

        // Everything else is a resource path inside this dictionary.
        let resourcePath = components.joined(separator: "/")
        if !resourcePath.isEmpty,
           let data = try? library.resource(path: resourcePath, dictionaryUUID: uuid) {
            return (data, Self.mimeType(forPath: resourcePath))
        }

        // Root-relative requests generated by dictionary JS resolve to
        // dict://d/<path> and lose the UUID; the first component is then not
        // a dictionary. Search all enabled dictionaries for the full path.
        if !library.isKnownDictionaryUUID(uuid) {
            let fullPath = ([uuid] + components).joined(separator: "/")
            if let data = try? library.resourceSearchingAllDictionaries(path: fullPath) {
                return (data, Self.mimeType(forPath: fullPath))
            }
        }
        return nil
    }

    nonisolated static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
