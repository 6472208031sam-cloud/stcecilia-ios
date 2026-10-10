import Foundation

/// POSTs arrival alerts to the private ntfy.sh topic, same as Android's
/// TrackingService.sendNtfy().
enum NtfyClient {
    static func post(topic: String, message: String) {
        guard let url = URL(string: "https://ntfy.sh/" + topic) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = message.data(using: .utf8)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }
}
