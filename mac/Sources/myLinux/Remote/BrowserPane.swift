import AppKit
import WebKit
import Network

/// A browser beside a machine's terminal: WebKit with an address bar, all its traffic through the machine's SOCKS
/// tunnel, so `localhost` is the machine's. Cookies and history are kept per machine.
final class BrowserPane: NSView, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    private let address = NSTextField()
    private let back = NSButton(), forward = NSButton(), reload = NSButton()
    private let bar = NSView()
    var onTitle: ((String) -> Void)?
    /// Asked for a Mac port that leads to the machine's port (nil when it cannot be opened).
    var localForward: ((Int, @escaping (UInt16?) -> Void) -> Void)?
    /// Mac port -> the machine's port, for the address bar and for telling forwards from real Mac addresses.
    private var forwards: [Int: Int] = [:]
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    init(machineID: UUID, socksPort: UInt16) {
        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore(forIdentifier: machineID)
        store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: socksPort)!))]
        config.websiteDataStore = store
        config.preferences.isElementFullscreenEnabled = true
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        web.navigationDelegate = self; web.uiDelegate = self
        web.customUserAgent = nil
        web.allowsBackForwardNavigationGestures = true
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .texturedRounded; b.isBordered = false; b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return b
        }
        let backB = button("chevron.left", "Back", #selector(goBack)), fwdB = button("chevron.right", "Forward", #selector(goForward)), reloadB = button("arrow.clockwise", "Reload", #selector(reloadPage))
        address.placeholderString = "localhost:3000, or any address; the machine's network"
        address.font = NSFont.systemFont(ofSize: 12); address.bezelStyle = .roundedBezel
        address.target = self; address.action = #selector(addressEntered)
        address.cell?.sendsActionOnEndEditing = false
        let stack = NSStackView(views: [backB, fwdB, reloadB, address])
        stack.orientation = .horizontal; stack.spacing = 4; stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
            web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Opens what was typed: a full URL as it is, "host:port" or "host/path" as http.
    func load(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s) else { return }
        web.load(URLRequest(url: url))
    }
    func load(_ url: URL) {
        // the machine's localhost: through a forward to a Mac port (WebKit never proxies local addresses)
        if let host = url.host?.lowercased(), BrowserPane.localHosts.contains(host), let forward = localForward {
            let guestPort = url.port ?? (url.scheme == "https" ? 443 : 80)
            if host == "127.0.0.1", forwards[guestPort] != nil { web.load(URLRequest(url: url)); return }   // already a forward
            forward(guestPort) { [weak self] macPort in
                guard let self else { return }
                guard let macPort, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    self.web.loadHTMLString(BrowserPane.message("Cannot reach the machine's port \(guestPort).", "The tunnel into the machine did not come up. Is it running, and is SSH reachable?"), baseURL: nil)
                    return
                }
                c.host = "127.0.0.1"; c.port = Int(macPort)
                self.forwards[Int(macPort)] = guestPort
                if let u = c.url { self.web.load(URLRequest(url: u)) }
            }
            return
        }
        web.load(URLRequest(url: url))
    }

    /// What the bar shows: a forwarded address as the machine's localhost address.
    private func shown(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.host == "127.0.0.1", let p = url.port, let guest = forwards[p], var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.host = "localhost"; c.port = guest == 80 ? nil : guest
            return c.url?.absoluteString ?? url.absoluteString
        }
        return url.absoluteString == "about:blank" ? "" : url.absoluteString
    }
    static func message(_ title: String, _ text: String) -> String {
        "<html><body style='font: 13px -apple-system; color: #888; padding: 24px'><b>\(title)</b><br>\(text)</body></html>"
    }
    /// The page the pane starts on when the terminal has shown no address yet.
    func showStart() {
        web.loadHTMLString(BrowserPane.message("The machine's browser.", "Addresses go through the machine: <code>localhost:3000</code> is what runs inside it, and the internet is what it sees. ⌘-click a link in the terminal to open it here."), baseURL: nil)
    }

    func snapshot(_ completion: @escaping (NSImage?) -> Void) {
        web.takeSnapshot(with: nil) { image, _ in completion(image) }
    }

    @objc private func goBack() { web.goBack() }
    @objc private func goForward() { web.goForward() }
    @objc private func reloadPage() { web.reload() }
    @objc private func addressEntered() { load(address.stringValue); window?.makeFirstResponder(web) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        address.stringValue = shown(webView.url)
    }
    /// Links and redirects to the machine's localhost go through a forward too.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, let host = u.host?.lowercased(), BrowserPane.localHosts.contains(host), localForward != nil,
           !(host == "127.0.0.1" && forwards[u.port ?? 80] != nil) {
            decisionHandler(.cancel); load(u); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        address.stringValue = shown(webView.url)
        onTitle?(webView.title ?? "")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("browser pane: navigation failed: %@", error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        NSLog("browser pane: %@ failed: %@ (%@ %d)", webView.url?.absoluteString ?? "?", e.localizedDescription, e.domain, e.code)
        guard e.code != NSURLErrorCancelled else { return }
        webView.loadHTMLString(BrowserPane.message("Cannot open the page.", "\(e.localizedDescription)<br><br>Addresses go through the machine: <code>localhost:3000</code> is what runs inside it."), baseURL: nil)
    }
    /// target=_blank and window.open stay in this pane
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }
}
