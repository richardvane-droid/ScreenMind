import AppKit
import WebKit
import ScreenMindCore

/// Hosts the React web-app configuration UI inside a WKWebView.
/// The window is a singleton — show/hide via `showWindow(_:)`.
final class SettingsWindowController: NSWindowController, WKNavigationDelegate, WKScriptMessageHandler {

    static let shared = SettingsWindowController()

    private var webView: WKWebView!

    // MARK: - Init

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "ScreenMind 偏好设置"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupWebView()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - WKWebView setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        // Register message handler: JS calls window.webkit.messageHandlers.screenMind.postMessage(...)
        config.userContentController.add(self, name: "screenMind")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        window?.contentView = webView
        loadWebApp()
    }

    private func loadWebApp() {
        // In production: load from app bundle (dist/ folder built by `npm run build`)
        if let distURL = Bundle.main.url(forResource: "index", withExtension: "html",
                                         subdirectory: "web-config/dist") {
            webView.loadFileURL(distURL, allowingReadAccessTo: distURL.deletingLastPathComponent())
        } else {
            // Dev fallback: load local dev server
            let devURL = URL(string: "http://localhost:5173")!
            webView.load(URLRequest(url: devURL))
        }
    }

    // MARK: - Swift → JS

    /// Send data to the web app.
    func sendToJS(_ message: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        let js = "window.onSwiftMessage(\(jsonString))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - JS → Swift (WKScriptMessageHandler)

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "saveConfig":
            handleSaveConfig(data: body["data"] as? [String: Any] ?? [:])
        case "getConfig":
            sendConfig()
        case "saveSuggestion":
            handleSaveSuggestion(data: body["data"] as? [String: Any] ?? [:])
        case "deleteSuggestion":
            handleDeleteSuggestion(id: body["id"] as? String ?? "")
        case "saveAPIKey":
            if let key = body["key"] as? String {
                KeychainHelper.write(key: "doubao_api_key", value: key)
                sendToJS(["type": "apiKeySaved", "success": true])
            }
        default:
            print("[Settings] Unknown JS action: \(action)")
        }
    }

    // MARK: - Config handlers (stubs — wire to PersistenceController in M3)

    private func handleSaveConfig(data: [String: Any]) {
        // TODO M3: save to AppConfig Core Data entity
        sendToJS(["type": "configSaved", "success": true])
    }

    private func sendConfig() {
        // TODO M3: read from AppConfig Core Data entity
        let defaults: [String: Any] = [
            "type": "configData",
            "baseAnxietyThreshold": 0.6,
            "samplingIntervalSeconds": 30,
            "cooldownMinutes": 5
        ]
        sendToJS(defaults)
    }

    private func handleSaveSuggestion(data: [String: Any]) {
        // TODO M3: CRUD for RelaxationSuggestion
        sendToJS(["type": "suggestionSaved", "success": true])
    }

    private func handleDeleteSuggestion(id: String) {
        // TODO M3: delete suggestion by UUID
        sendToJS(["type": "suggestionDeleted", "success": true])
    }
}
