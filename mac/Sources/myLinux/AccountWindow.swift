import AppKit
import WebKit

/// mylinux.app in a window of its own, about the size of a large phone: the account (sign in, the machines, API
/// tokens) beside the launcher. Its cookies are kept in a WebKit store of its own, so the sign-in lasts. Sign-in
/// flows that open a popup (Google's) get a real popup window; other links that open a new window go to the browser.
final class AccountWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let home = URL(string: ProcessInfo.processInfo.environment["MYLINUX_ACCOUNT_URL"] ?? "https://mylinux.app/app")!
    /// the WebKit store: one, always the same, so the session survives restarts
    private static let storeID = UUID(uuidString: "6D794C69-6E75-7841-6363-6F756E740001")!
    private static var shared: AccountWindow?

    let window: NSWindow
    let web: WKWebView
    private let back = NSButton(), reload = NSButton()
    private let place = NSTextField(labelWithString: "")
    private var popups: [NSWindow] = []
    /// the address and title as the page changes them itself (pushState), not only on loads
    private var watches: [NSKeyValueObservation] = []

    static func show() {
        NSApp.activate()
        if let a = shared { a.window.makeKeyAndOrderFront(nil); return }
        let a = AccountWindow()
        shared = a
        a.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // as Safari: some sign-in services (Google's) refuse what they take for an embedded web view
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "mylinux.app"
        window.minSize = NSSize(width: 360, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("mylinux.app account")
        web.navigationDelegate = self; web.uiDelegate = self

        func button(_ b: NSButton, _ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.target = self; b.action = action; b.toolTip = tip
            b.bezelStyle = .texturedRounded; b.isBordered = false
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return b
        }
        place.font = NSFont.systemFont(ofSize: 12); place.textColor = .secondaryLabelColor
        place.lineBreakMode = .byTruncatingMiddle; place.alignment = .center
        place.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let home = button(NSButton(), "house", "Your account", #selector(goHome))
        let browser = button(NSButton(), "safari", "Open in the browser", #selector(openInBrowser))
        let bar = NSStackView(views: [button(back, "chevron.left", "Back", #selector(goBack)), home, place,
                                      button(reload, "arrow.clockwise", "Reload", #selector(reloadPage)), browser])
        bar.orientation = .horizontal; bar.spacing = 4; bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        web.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(bar); root.addSubview(web)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor), bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 32),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor), web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor), web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        web.load(Self.fresh(Self.home))
        watches = [web.observe(\.url) { [weak self] _, _ in DispatchQueue.main.async { self?.update() } },
                   web.observe(\.title) { [weak self] _, _ in DispatchQueue.main.async { self?.update() } },
                   web.observe(\.canGoBack) { [weak self] _, _ in DispatchQueue.main.async { self?.update() } }]
        update()
    }

    /// For the test hook: the page's path and how much the account app has drawn, or MYLINUX_TEST_JS's answer (an
    /// async function body).
    static func testPage(_ done: @escaping (String) -> Void) {
        guard let a = shared else { return done("no window") }
        if let js = ProcessInfo.processInfo.environment["MYLINUX_TEST_JS"] {
            a.web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
                switch r { case .success(let v): done("\(v)"); case .failure(let e): done("error: \(e.localizedDescription)") }
            }
            return
        }
        a.web.evaluateJavaScript("location.pathname + ' drawn=' + (document.getElementById('root') || {innerHTML: ''}).innerHTML.length") { r, e in
            done((r as? String) ?? "error: \(e?.localizedDescription ?? "?")")
        }
    }

    func windowWillClose(_ notification: Notification) {
        popups.forEach { $0.close() }; popups.removeAll()
        Self.shared = nil
    }

    @objc private func goBack() { web.goBack() }
    @objc private func goHome() { web.load(Self.fresh(Self.home)) }

    /// The page itself fresh from the site (a cached copy would name the scripts of an older version); the scripts it
    /// names have their version in their names and still come from the cache.
    static func fresh(_ url: URL) -> URLRequest { URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData) }
    @objc private func reloadPage() { web.reload() }
    @objc private func openInBrowser() { if let u = web.url { NSWorkspace.shared.open(u) } }

    private func update() {
        back.isEnabled = web.canGoBack
        let host = web.url?.host ?? Self.home.host ?? ""
        place.stringValue = host + (web.url.map { $0.path == "/" ? "" : $0.path } ?? "")
        if let t = web.title, !t.isEmpty { window.title = t } else { window.title = "mylinux.app" }
    }

    // ---- navigation ----
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === web { update() }
        else if let w = popups.first(where: { $0.contentView === webView }), let t = webView.title, !t.isEmpty { w.title = t }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if webView === web { update() } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        guard e.code != NSURLErrorCancelled, webView === web else { return }
        let text = e.localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        webView.loadHTMLString("""
            <html><body style="font: 14px -apple-system; color: #888; padding: 40px 24px; text-align: center">
            <p style="font-size: 16px; color: #ccc">Cannot open mylinux.app.</p><p>\(text)</p>
            <p><a href="\(Self.home.absoluteString)" style="color: #4a8cff">Try again</a></p></body></html>
            """, baseURL: nil)
    }

    /// window.open and target=_blank: a sign-in (Google, GitHub, the site's own pages) gets a popup that can talk back to
    /// its opener; anything else (the docs, GitHub's pages) opens in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let host = url?.host?.lowercased() ?? ""
        let signIn = host.isEmpty || host.hasSuffix("mylinux.app") || host.hasSuffix("google.com") || host.hasSuffix("github.com") && url?.path.hasPrefix("/login") == true
            || host.hasSuffix("clerk.accounts.dev") || host.hasSuffix("apple.com") && url?.path.contains("auth") == true
        guard signIn else {
            if let url { NSWorkspace.shared.open(url) }
            return nil
        }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.navigationDelegate = self; popup.uiDelegate = self
        let w = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in"; w.contentView = popup; w.isReleasedWhenClosed = false
        var f = w.frame; f.origin = NSPoint(x: window.frame.midX - f.width / 2, y: window.frame.midY - f.height / 2); w.setFrame(f, display: false)
        popups.append(w)
        w.makeKeyAndOrderFront(nil)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) {
        if let w = popups.first(where: { $0.contentView === webView }) { w.close(); popups.removeAll { $0 === w } }
    }
}
