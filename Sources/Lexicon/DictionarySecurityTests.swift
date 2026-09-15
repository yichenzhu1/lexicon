import AppKit
import WebKit

/// Exercise real custom-scheme responses: raw local HTML must obey the same
/// offline setting as the generated entry, including same-origin child pages.
@MainActor
enum DictionarySecurityTests {
    @MainActor
    private final class Probe: NSObject, WKScriptMessageHandler {
        var blockedByPath: [String: Bool] = [:]

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let payload = message.body as? [String: Any],
                  let path = payload["path"] as? String,
                  let blocked = payload["blocked"] as? Bool
            else { return }
            blockedByPath[path] = blocked
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() async throws -> Int {
        let files = FileManager.default
        let root = files.temporaryDirectory
            .appendingPathComponent("LexiconDictionarySecurityTests-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/basic.mdx")
        let mdx = source.appendingPathComponent("basic.mdx")
        try files.copyItem(at: fixture, to: mdx)
        try ("<iframe src='nested.html'></iframe>" + probeScript)
            .write(to: source.appendingPathComponent("probe.html"), atomically: true, encoding: .utf8)
        try probeScript.write(
            to: source.appendingPathComponent("nested.html"), atomically: true, encoding: .utf8
        )

        let model = LibraryModel(rootURL: root.appendingPathComponent("library"))
        guard let library = model.library else {
            throw Failure(description: "security fixture library was unavailable")
        }
        let dictionary = try library.importDictionary(from: mdx)
        let handler = DictSchemeHandler(libraryModel: model)
        handler.allowHTTPS = false
        let probe = Probe()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: DictSchemeHandler.scheme)
        configuration.userContentController.add(probe, name: "securityProbe")
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration
        )
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = view
        window.orderBack(nil)
        defer {
            view.stopLoading()
            configuration.userContentController.removeScriptMessageHandler(forName: "securityProbe")
            window.orderOut(nil)
        }
        let url = URL(string: "dict://\(dictionary.uuid.lowercased())/probe.html")!
        view.load(URLRequest(url: url))
        let deadline = ContinuousClock.now + .seconds(5)
        while probe.blockedByPath.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        for path in ["/probe.html", "/nested.html"] {
            guard probe.blockedByPath[path] == true else {
                throw Failure(description: "offline CSP did not block HTTPS in \(path): \(probe.blockedByPath)")
            }
        }
        return 2
    }

    // Only a closed loopback port is addressed if the policy regresses. A
    // network failure alone is insufficient: require a real CSP violation.
    private static let probeScript = #"""
    <script>
    let blocked = false;
    document.addEventListener('securitypolicyviolation', event => {
      if (event.effectiveDirective === 'connect-src') blocked = true;
    });
    fetch('https://127.0.0.1:9/lexicon-security-test').catch(() => {});
    setTimeout(() => webkit.messageHandlers.securityProbe.postMessage({
      path:location.pathname, blocked
    }), 250);
    </script>
    """#
}
