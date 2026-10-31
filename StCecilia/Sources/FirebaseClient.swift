import Foundation

/// Live Tracker (v50): PUTs this phone's live position record to the
/// Firebase Realtime Database — SDK-free, over the RTDB REST API —
/// in the same fire-and-forget shape as NtfyClient. The positions
/// path is a secret: the URL is never logged.
enum FirebaseClient {
    static func put(base: String, path: String, tag: String, body: [String: Any], completion: ((Int?) -> Void)? = nil) {
        guard let url = URL(string: base + "/" + path + "/" + tag + ".json") else { completion?(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            completion?((resp as? HTTPURLResponse)?.statusCode)
        }.resume()
    }
}
