import AppKit
import SwiftUI
import WebKit

/// Offscreen SwiftUI/WebKit check for the resident-tab view hierarchy.
@MainActor
enum TabWebViewSmokeTest {
    private static var window: NSWindow?
    private static var hostingView: NSHostingView<AnyView>?
    private static var appState: AppState?
    private static var rootURL: URL?
    private static var initialTabID: UUID?
    private static var initialWebView: WKWebView?
    private static var residentIdentities: [UUID: ObjectIdentifier] = [:]
    private static var phase = 0
    private static var attempts = 0

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LexiconTabWebViewTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = root
        let model = LibraryModel(rootURL: root)
        let state = AppState(libraryModel: model)
        appState = state
        initialTabID = state.activeTabID

        let content = AnyView(
            ContentView()
                .environmentObject(model)
                .environmentObject(state)
                .frame(width: 900, height: 640)
        )
        let host = NSHostingView(rootView: content)
        hostingView = host
        let testWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        testWindow.contentView = host
        testWindow.orderBack(nil)
        window = testWindow

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in poll() }
        }
        app.run()
        exit(1)
    }

    private static func poll() {
        attempts += 1
        guard let state = appState, let host = hostingView, let initialTabID else {
            finish("test state was released", success: false)
        }
        let views = webViews(in: host)
        let byTab = Dictionary(uniqueKeysWithValues: views.compactMap { view -> (UUID, WKWebView)? in
            guard let raw = view.identifier?.rawValue, let id = UUID(uuidString: raw) else { return nil }
            return (id, view)
        })

        switch phase {
        case 0:
            guard let first = byTab[initialTabID] else { return timeoutIfNeeded() }
            initialWebView = first
            for _ in 0..<4 { state.openNewTab() }
            phase = 1
            attempts = 0

        case 1:
            guard byTab.count == AppState.maximumResidentTabCount,
                  Set(byTab.keys) == Set(state.residentTabIDs)
            else { return timeoutIfNeeded() }
            guard byTab[initialTabID] == nil else {
                finish("the least-recent tab view was not evicted", success: false)
            }
            residentIdentities = byTab.mapValues(ObjectIdentifier.init)
            guard let residentToActivate = state.residentTabIDs.dropLast().last else {
                finish("no inactive resident tab was available", success: false)
            }
            state.activateTab(residentToActivate)
            phase = 2
            attempts = 0

        case 2:
            guard byTab.count == AppState.maximumResidentTabCount else { return timeoutIfNeeded() }
            let identities = byTab.mapValues(ObjectIdentifier.init)
            guard identities == residentIdentities else {
                finish("switching to a resident tab recreated a WKWebView", success: false)
            }
            state.activateTab(initialTabID)
            phase = 3
            attempts = 0

        case 3:
            guard byTab.count == AppState.maximumResidentTabCount,
                  Set(byTab.keys) == Set(state.residentTabIDs),
                  let reloaded = byTab[initialTabID],
                  !reloaded.isLoading, reloaded.url?.host == "page"
            else { return timeoutIfNeeded() }
            guard reloaded !== initialWebView else {
                finish("reactivating an evicted tab reused its released WKWebView", success: false)
            }
            phase = 4
            attempts = 0
            reloaded.callAsyncJavaScript(
                translationCompatibilityTests,
                arguments: [:], in: nil, in: .page
            ) { result in
                switch result {
                case .success(let value):
                    guard let checks = value as? Int, checks >= 19 else {
                        finish("translation checks returned \(String(describing: value))", success: false)
                    }
                    finish("TAB WEBVIEW OK (\(checks) translation bridge checks)", success: true)
                case .failure(let error):
                    finish("translation bridge: \(error)", success: false)
                }
            }

        default:
            timeoutIfNeeded()
        }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let webView = view as? WKWebView { found.append(webView) }
        for child in view.subviews { found.append(contentsOf: webViews(in: child)) }
        return found
    }

    private static func timeoutIfNeeded() {
        if attempts > 100 { finish("timed out waiting for the resident view hierarchy", success: false) }
    }

    /// Exercise the actual adapter in WebKit without network traffic, keys or
    /// installed Apple language packs. The app-owned welcome page has no native
    /// translation consumer, so this mock supplies deterministic responses.
    private static let translationCompatibilityTests = #"""
    const endpoint = 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';
    const socketEndpoint = 'wss://maas-api.cn-huabei-1.xf-yun.com/v1/chat';
    const body = JSON.stringify({messages:[{role:'user', content:'Translate this sentence.'}]});
    const requests = [], cancellations = [];
    let mode = 'success', checks = 0;
    const translated = '<m>中文</m><img src=x onerror=alert(1)>&"';
    function check(condition, message) { if (!condition) throw new Error(message); checks++; }
    function respond(requestID, text, error) {
      dispatchEvent(new CustomEvent('lexicon-translation-response', {
        detail:JSON.stringify({requestID, text, error})
      }));
    }
    function receive(event) {
      if (event.source !== window) return;
      if (event.data?.kind === 'lexicon-translation-cancel') {
        cancellations.push(event.data.requestID); return;
      }
      if (event.data?.kind !== 'lexicon-translation-request') return;
      const request = JSON.parse(event.data.detail);
      requests.push(request);
      if (mode === 'success') respond(request.requestID, translated);
      else if (mode === 'failure') respond(request.requestID, null, 'Install the English and Chinese language packs.');
    }
    addEventListener('message', receive);
    const pause = () => new Promise(resolve => setTimeout(resolve, 5));
    async function until(predicate) {
      for (let attempt = 0; attempt < 200 && !predicate(); attempt++) await pause();
      if (!predicate()) throw new Error('Timed out waiting for a translation bridge event');
    }
    const fetchTranslation = options => fetch(endpoint, {method:'POST', body, ...options});
    async function openSocket() {
      const socket = new WebSocket(socketEndpoint);
      await new Promise(resolve => socket.onopen = resolve);
      return socket;
    }
    const socketBody = JSON.stringify({payload:{message:{text:[{role:'user', content:'Translate.'}]}}});
    const nativeSetTimeout = window.setTimeout;
    try {
      const response = await fetchTranslation();
      const stream = await response.text();
      check(response.ok && response.headers.get('Content-Type').includes('text/event-stream'), 'fetch did not return SSE');
      check(stream.includes('<m>中文</m>') && stream.includes('&lt;img') && !stream.includes('<img'), 'fetch response markup was unsafe');
      check(stream.endsWith('data: [DONE]\n\n'), 'fetch stream never finished');
      const requestResponse = await fetch(new Request(endpoint, {
        method:'POST', headers:{Authorization:'Bearer dictionary-secret'},
        body:JSON.stringify({messages:[{role:'user',content:'Earlier'}, {role:'assistant',content:'Old'},
          {role:'user',content:'Latest'}]})
      }));
      check(requestResponse.ok && requests.at(-1).prompt === 'Latest', 'Request input or latest user message was lost');
      check(Object.keys(requests.at(-1)).sort().join(',') === 'prompt,requestID', 'dictionary credentials entered the bridge');
      check((await fetch(new URL(endpoint), {method:'POST', body})).ok, 'URL input was not intercepted');

      mode = 'failure';
      const failure = await fetchTranslation();
      check(failure.status === 502 && (await failure.json()).error.message.includes('language packs'), 'native translation error was lost');
      const beforeInvalid = requests.length;
      check((await fetchTranslation({body:'invalid json'})).status === 400, 'malformed request was accepted');
      check((await fetchTranslation({body:'{"messages":[]}'})).status === 400 && requests.length === beforeInvalid,
        'missing passage reached the native bridge');

      const alreadyAborted = new AbortController(); alreadyAborted.abort();
      let abortName;
      try { await fetchTranslation({signal:alreadyAborted.signal}); } catch (error) { abortName = error.name; }
      check(abortName === 'AbortError' && requests.length === beforeInvalid, 'already-aborted fetch was submitted');

      mode = 'defer';
      const controller = new AbortController();
      const inFlight = fetchTranslation({signal:controller.signal}).catch(error => error.name);
      await until(() => requests.length > beforeInvalid);
      const abortedID = requests.at(-1).requestID;
      controller.abort();
      check(await inFlight === 'AbortError', 'in-flight fetch did not reject on abort');
      await until(() => cancellations.includes(abortedID));
      respond(abortedID, 'This late response must be ignored.');
      check(cancellations.filter(id => id === abortedID).length === 1, 'fetch cancellation was not forwarded once');

      mode = 'success';
      const successSocket = await openSocket();
      const socketResult = new Promise(resolve => successSocket.onmessage = event => resolve(JSON.parse(event.data)));
      successSocket.send(socketBody);
      const socketData = await socketResult;
      check(socketData.payload.choices.text[0].content.includes('&lt;m&gt;')
        && successSocket.readyState === WebSocket.CLOSED, 'socket markup or close lifecycle was wrong');

      mode = 'failure';
      const errorSocket = await openSocket();
      let errorMessage;
      errorSocket.onerror = event => errorMessage = event.message;
      const closed = new Promise(resolve => errorSocket.onclose = resolve);
      errorSocket.send(socketBody);
      check((await closed).code === 1011 && errorMessage.includes('language packs'), 'socket error details were lost');

      mode = 'defer';
      const cancelSocket = await openSocket();
      const beforeSocket = requests.length;
      let lateMessages = 0;
      cancelSocket.onmessage = () => lateMessages++;
      cancelSocket.send(socketBody);
      await until(() => requests.length > beforeSocket);
      const closedID = requests.at(-1).requestID;
      cancelSocket.close();
      await until(() => cancellations.includes(closedID));
      respond(closedID, 'Late socket result');
      check(lateMessages === 0 && cancelSocket.readyState === WebSocket.CLOSED, 'closed socket accepted a late result');

      window.setTimeout = (callback, delay, ...args) => nativeSetTimeout(callback, delay === 60000 ? 20 : delay, ...args);
      const timedOut = await fetchTranslation();
      const timeoutID = requests.at(-1).requestID;
      await until(() => cancellations.includes(timeoutID));
      check(timedOut.status === 504, 'fetch timeout did not cancel its native request');
      window.setTimeout = nativeSetTimeout;

      const frame = document.createElement('iframe');
      const loaded = new Promise(resolve => frame.onload = resolve);
      frame.srcdoc = '<button>Translate</button>';
      document.body.appendChild(frame);
      await loaded;
      try {
        const child = frame.contentWindow;
        child.document.querySelector('button').click();
        const withoutClick = await child.fetch(endpoint, {method:'POST', body});
        check(withoutClick.status === 502 && (await withoutClick.json()).error.message.includes('Click'),
          'an untrusted click was not rejected promptly across content worlds');
        const oversized = await child.fetch(endpoint, {method:'POST', body:JSON.stringify({
          messages:[{role:'user', content:'中'.repeat(7000)}]
        })});
        check(oversized.status === 502 && (await oversized.json()).error.message.includes('too long'),
          'oversized UTF-8 prompt did not fail promptly');
      } finally { frame.remove(); }

      const beforePageHide = requests.length;
      const pageRequest = fetchTranslation().catch(error => error.name);
      await until(() => requests.length > beforePageHide);
      const pageRequestID = requests.at(-1).requestID;
      dispatchEvent(new Event('pagehide'));
      check(await pageRequest === 'AbortError', 'page exit did not cancel its fetch');
      await until(() => cancellations.includes(pageRequestID));
      return checks;
    } finally {
      window.setTimeout = nativeSetTimeout;
      removeEventListener('message', receive);
    }
    """#

    private static func finish(_ message: String, success: Bool) -> Never {
        print(success ? message : "TAB WEBVIEW FAIL: \(message)")
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        appState = nil
        initialWebView = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        exit(success ? 0 : 1)
    }
}
