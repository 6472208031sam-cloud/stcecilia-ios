import UIKit
import WebKit

/// Single full-screen WKWebView over the live St Cecilia page.
/// Mirrors Android's MainActivity: the page is the UI, the native side owns
/// background tracking and feeds the page through the NativeBridge shim.
class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static weak var shared: ViewController?

    private static let pageURL = URL(
        string: "https://6472208031sam-cloud.github.io/bus-stop-alerts/st-cecilia.html")!

    private var webView: WKWebView!
    private var autoStartDone = false

    override func viewDidLoad() {
        super.viewDidLoad()
        ViewController.shared = self

        let config = WKWebViewConfiguration()
        let shim = WKUserScript(source: NativeBridge.shimSource,
                                injectionTime: .atDocumentStart,
                                forMainFrameOnly: true)
        config.userContentController.addUserScript(shim)

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        LocationTracker.shared.jsEval = { [weak self] js in
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        LocationTracker.shared.onAutoStarted = { [weak self] in
            self?.eval("if (typeof nativeAutoStarted === 'function') { try { nativeAutoStarted(); } catch(e){} }")
        }

        webView.load(URLRequest(url: Self.pageURL))
    }

    // MARK: - Page lifecycle (mirrors MainActivity)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Push the latest config (arms the schedule), then auto-start
        // tracking once per app launch like Android does.
        eval("if (typeof updateConfig === 'function') { try { updateConfig(); } catch(e){} }")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, !self.autoStartDone else { return }
            self.autoStartDone = true
            // A tapped schedule notification takes precedence over the
            // generic auto-start (it carries the right tab).
            if !self.startScheduledRideIfPending() {
                self.eval("(function(){ try { if (typeof startTracking === 'function') startTracking(); } catch(e){} })()")
            }
        }
    }

    /// Starts the ride for the tab named by a tapped schedule notification.
    /// Returns true if a scheduled ride was started.
    @discardableResult
    func startScheduledRideIfPending() -> Bool {
        guard let tab = LocationTracker.shared.pendingScheduledTab else { return false }
        LocationTracker.shared.pendingScheduledTab = nil
        guard let cfg = ScheduleManager.shared.configJSON(forTab: tab),
              LocationTracker.shared.startRide(configJson: cfg, scheduled: true) == "started"
        else { return false }
        eval("if (typeof nativeAutoStarted === 'function') { try { nativeAutoStarted(); } catch(e){} }")
        LocationTracker.shared.pushSync(toast: nil)
        return true
    }

    private func eval(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - NativeBridge prompt interception

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        if prompt.hasPrefix(NativeBridge.promptPrefix) {
            completionHandler(NativeBridge.shared.handle(prompt: prompt))
        } else {
            // Not ours — mimic the default behavior.
            completionHandler(defaultText)
        }
    }
}
