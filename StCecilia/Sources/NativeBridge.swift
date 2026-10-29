import Foundation
import UIKit

/// Exposes `window.NativeBridge` to the web page with the SAME interface as
/// the Android app: startRide(configJson) -> "started"/"permission_needed"/"error",
/// stopRide(), updateConfig(configJson), getStatus() -> JSON string,
/// hasBackgroundPermission() -> Bool.
///
/// Transport note: iOS's WKScriptMessageHandler (window.webkit.messageHandlers)
/// is fire-and-forget and CANNOT return a value to JavaScript, but the page
/// reads these return values synchronously (exactly like Android's
/// @JavascriptInterface). So the shim below routes calls through a
/// prompt() interception instead: the Swift WKUIDelegate catches prompts with
/// our prefix, runs the call synchronously, and returns a JSON response.
/// This is a well-known WKWebView technique and preserves the exact Android
/// call semantics the page expects.
final class NativeBridge {
    static let shared = NativeBridge()
    static let promptPrefix = "__stc_bridge__::"

    /// Injected at document start so `!!(window.NativeBridge)` is true
    /// before the page's own scripts run.
    static let shimSource = """
    (function() {
      if (window.NativeBridge) return;
      var PREFIX = '__stc_bridge__::';
      function call(method, arg) {
        var payload;
        try { payload = JSON.stringify({m: method, a: (arg === undefined ? null : arg)}); }
        catch (e) { return null; }
        var resp = prompt(PREFIX + payload);
        if (!resp) return null;
        try {
          var o = JSON.parse(resp);
          return (o && o.ok) ? o.v : null;
        } catch (e) { return null; }
      }
      window.NativeBridge = {
        startRide: function(cfg) {
          var r = call('startRide', cfg);
          return (typeof r === 'string') ? r : 'error';
        },
        stopRide: function() { call('stopRide'); },
        markReached: function() { call('markReached'); },
        skipNext: function() { call('skipNext'); },
        updateConfig: function(cfg) { call('updateConfig', cfg); },
        getStatus: function() {
          var r = call('getStatus');
          return (typeof r === 'string') ? r : '';
        },
        hasBackgroundPermission: function() {
          return call('hasBackgroundPermission') === true;
        },
        getNativeLogs: function() {
          var r = call('getNativeLogs');
          return (typeof r === 'string') ? r : '';
        },
        clearNativeLogs: function() { call('clearNativeLogs'); },
        downloadLogs: function(filename, text) {
          var r = call('downloadLogs', filename + '\\n' + text);
          return (typeof r === 'string') ? r : '';
        }
      };
    })();
    """

    /// Handles an intercepted bridge prompt; returns the JSON string passed
    /// back to JavaScript: {"ok":true,"v":<value>}.
    func handle(prompt: String) -> String {
        let payload = String(prompt.dropFirst(Self.promptPrefix.count))
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["m"] as? String else {
            return jsonResponse(nil)
        }
        let arg = obj["a"] as? String
        switch method {
        case "startRide":
            return jsonResponse(LocationTracker.shared.startRide(configJson: arg))
        case "stopRide":
            LocationTracker.shared.stopRide()
            return jsonResponse(nil)
        case "markReached":
            LocationTracker.shared.markReached()
            return jsonResponse(nil)
        case "skipNext":
            LocationTracker.shared.skipNext()
            return jsonResponse(nil)
        case "updateConfig":
            LocationTracker.shared.updateConfig(configJson: arg)
            return jsonResponse(nil)
        case "getStatus":
            return jsonResponse(LocationTracker.shared.statusJson())
        case "hasBackgroundPermission":
            return jsonResponse(LocationTracker.shared.hasBackgroundPermission)
        case "getNativeLogs":
            return jsonResponse(LocationTracker.shared.nativeLogsText())
        case "clearNativeLogs":
            LocationTracker.shared.clearNativeLogs()
            return jsonResponse(nil)
        case "downloadLogs":
            return jsonResponse(Self.presentLogShare(arg))
        default:
            return jsonResponse(nil)
        }
    }

    /// v47: writes the page-assembled log export to a temp file and
    /// presents the share sheet (Save to Files / Mail / AirDrop). The
    /// shim packs "filename\ntext" into the single bridge argument.
    /// Returns the status string the page toasts.
    private static func presentLogShare(_ arg: String?) -> String {
        guard let arg = arg, let nl = arg.firstIndex(of: "\n") else { return "Download failed." }
        let filename = String(arg[arg.startIndex..<nl])
        let text = String(arg[arg.index(after: nl)...])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { return "Download failed." }
        DispatchQueue.main.async {
            guard let vc = topViewController() else { return }
            let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            avc.popoverPresentationController?.sourceView = vc.view
            vc.present(avc, animated: true)
        }
        return "Share sheet opened."
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }

    private func jsonResponse(_ value: Any?) -> String {
        let dict: [String: Any] = ["ok": true, "v": value ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"ok\":false}"
    }
}
