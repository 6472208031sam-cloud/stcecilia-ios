import Foundation
import CoreLocation
import UserNotifications
import AudioToolbox
import UIKit

/// Owns background GPS tracking, arrival detection, alert sound/vibration,
/// follower ntfy pushes and local notifications.
/// Port of Android's TrackingService (foreground service + wake lock).
/// On iOS the UIBackgroundModes=location capability keeps updates flowing
/// with the screen off — no wake lock concept exists.
final class LocationTracker: NSObject {
    static let shared = LocationTracker()

    private let manager = CLLocationManager()
    private var ride: RideState?
    private var nearCount = 0
    private var nearTargetIdx = -1
    private var pendingConfig: String?

    /// Set by ViewController: evaluates JS in the page.
    var jsEval: ((String) -> Void)?
    /// Called when a permission-deferred ride auto-starts.
    var onAutoStarted: (() -> Void)?
    /// Tab requested by tapping a schedule notification.
    var pendingScheduledTab: String?

    var isTracking: Bool { ride != nil }

    var hasBackgroundPermission: Bool {
        CLLocationManager.authorizationStatus() == .authorizedAlways
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .automotiveNavigation
        // Setting this without the 'location' UIBackgroundModes key throws
        // NSException and kills the app at launch — guard it.
        let bgModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if bgModes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.pausesLocationUpdatesAutomatically = false
        if #available(iOS 11.0, *) {
            manager.showsBackgroundLocationIndicator = true
        }
    }

    // MARK: - Bridge API (mirrors Android NativeBridge + TrackingService)

    /// Returns "started" / "permission_needed" / "error", exactly like Android.
    func startRide(configJson: String?, scheduled: Bool = false) -> String {
        guard let configJson = configJson, !configJson.isEmpty,
              let data = configJson.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            return "error"
        }
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            pendingConfig = configJson
            manager.requestAlwaysAuthorization()
            return "permission_needed"
        case .authorizedAlways:
            break
        default:
            // denied / restricted / when-in-use: the page shows the
            // "Allow all the time" toast, same as Android.
            return "permission_needed"
        }
        // Already tracking: refresh config but keep the service's progress
        // (safer than Android's ACTION_START, which could wipe progress with
        // the page's stale flags on a mid-ride reopen).
        applyConfig(jsonString: configJson, keepProgress: ride != nil)
        ride?.scheduledRide = scheduled
        beginTracking()
        return "started"
    }

    func stopRide() {
        guard ride != nil else { return }
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        RideStore.clear()
        jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
    }

    func markReached() {
        guard let r = ride else { return }
        let idx = r.stops.firstIndex(where: { !$0.reached }) ?? -1
        if idx >= 0 && idx < r.stops.count {
            arrive(at: idx)
        }
    }

    func updateConfig(configJson: String?) {
        guard let configJson = configJson,
              let data = configJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let cfg = RideState(json: obj)
        // Always refresh the schedule (must survive with no active ride),
        // stop data only applies to a live ride — mirrors Android ACTION_UPDATE.
        ScheduleManager.shared.apply(config: cfg)
        if ride != nil {
            applyConfig(jsonString: configJson, keepProgress: true)
            pushSync(toast: nil)
        }
    }

    /// Status JSON for the WebView to resync; "" when no ride is active.
    /// A recently completed ride (within 15 min) is returned with
    /// active=false so the page can show the arrived UI after a background
    /// finish. Shape mirrors Android's getStatusJson().
    func statusJson() -> String {
        if let r = ride, !r.stops.isEmpty {
            return statusPayload(ride: r, active: true)
        }
        if let r = RideStore.load(), !r.stops.isEmpty, r.completed {
            if let at = r.completedAt, Date().timeIntervalSince(at) < 15 * 60 {
                return statusPayload(ride: r, active: false)
            }
            // Expired: drop it so a fresh page shows no ride.
            RideStore.clear()
        }
        return ""
    }

    private func statusPayload(ride r: RideState, active: Bool) -> String {
        let payload: [String: Any] = [
            "active": active,
            "completed": r.completed,
            "page": r.page,
            "tab": r.tab,
            "reached": r.stops.map { $0.reached },
            "skipped": r.stops.map { $0.skipped },
            "next": firstUnreached(r),
            "total": r.stops.count
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Resume a persisted ride on launch (mirrors Android's START_STICKY restart).
    /// A completed ride is for display only — never resume it as an active ride.
    func restore() {
        guard let r = RideStore.load(), !r.stops.isEmpty, !r.completed else { return }
        ride = r
        beginTracking()
    }

    // MARK: - Internals

    private func applyConfig(jsonString: String, keepProgress: Bool) {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let cfg = RideState(json: obj)
        if keepProgress, let r = ride, r.stops.count == cfg.stops.count {
            for i in 0..<cfg.stops.count {
                cfg.stops[i].reached = r.stops[i].reached
                cfg.stops[i].skipped = r.stops[i].skipped
            }
            cfg.scheduledRide = r.scheduledRide
        }
        ride = cfg
        ScheduleManager.shared.apply(config: cfg)
        persist()
    }

    private func beginTracking() {
        guard ride != nil else { return }
        nearCount = 0
        nearTargetIdx = -1
        persist()
        manager.startUpdatingLocation()
    }

    private func persist() {
        if let r = ride { RideStore.save(r) }
    }

    private func firstUnreached(_ r: RideState) -> Int {
        for i in 0..<r.stops.count {
            if !r.stops[i].reached { return i }
        }
        return -1
    }

    private func finishRide() {
        // Keep the state marked completed (with a timestamp) instead of
        // deleting it, so the WebView can show the arrived UI on resume.
        if let r = ride {
            r.completed = true
            r.completedAt = Date()
            RideStore.save(r)
        }
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        jsEval?("if (typeof nativeFinished === 'function') { try { nativeFinished(); } catch(e){} }")
    }

    // MARK: - Arrival detection (port of TrackingService.handleLocation)

    private func handleLocation(_ loc: CLLocation, accuracy: Double, ride r: RideState) {
        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        r.lastFixTime = Date()
        r.lastFixAccuracy = accuracy
        jsEval?("if (typeof nativePosition === 'function') { try { nativePosition(\(lat),\(lng),\(Int(accuracy))); } catch(e){} }")

        var idx = firstUnreached(r)
        // Snap-forward ONLY at ride start (no stops reached yet).
        // Mid-ride stays strictly sequential — never reintroduce mid-ride snap.
        if idx != -1 && idx == 0 && accuracy <= 150 {
            var best = -1
            var bestDist = Double.greatestFiniteMagnitude
            for i in idx..<r.stops.count {
                if r.stops[i].reached { continue }
                let d = haversine(lat1: lat, lon1: lng,
                                  lat2: r.stops[i].lat, lon2: r.stops[i].lng)
                if d < bestDist { bestDist = d; best = i }
            }
            if best > idx && bestDist <= r.snapDistance {
                for i in idx..<best {
                    r.stops[i].reached = true
                    r.stops[i].skipped = true
                }
                idx = best
                persist()
                pushSync(toast: "Starting from \(r.stops[best].label) — earlier stops skipped.")
            }
        }
        guard idx != -1 else { finishRide(); return }

        let stop = r.stops[idx]
        let distance = haversine(lat1: lat, lon1: lng, lat2: stop.lat, lon2: stop.lng)
        let limit = stop.acc ?? 50
        if distance <= stop.radius && accuracy <= limit {
            // Tier 1: confident fix — arrive immediately.
            arrive(at: idx)
        } else if distance <= 15 && accuracy <= 150 {
            // Very close to the pin — trust it even with moderate accuracy.
            arrive(at: idx)
        } else if accuracy <= 200 && distance <= stop.radius + accuracy {
            // Tier 2: poor accuracy (phone pocketed) — 3 consecutive fixes
            // near the stop confirm the arrival. A GPS jump won't persist.
            if nearTargetIdx != idx { nearTargetIdx = idx; nearCount = 0 }
            nearCount += 1
            if nearCount >= 3 {
                nearCount = 0
                nearTargetIdx = -1
                arrive(at: idx)
            }
        } else {
            nearCount = 0
            nearTargetIdx = -1
        }
    }

    private func arrive(at idx: Int) {
        guard let r = ride, idx < r.stops.count else { return }
        nearCount = 0
        nearTargetIdx = -1
        let stop = r.stops[idx]
        stop.reached = true
        let isFinal = idx == r.stops.count - 1
        if r.sound { AlertPlayer.shared.play() }
        vibrate()
        // Exact message formats from Android's TrackingService.onArrival.
        // (page is always "stcecilia" from the web page, so the tag is " (AM)"
        // exactly as on Android.)
        let routeTag = (r.tab == "pm") ? " (PM)" : " (AM)"
        let msg = isFinal
            ? "🚌 Final stop reached\(routeTag): \(stop.name)."
            : "🚌 \(stop.label) reached."
        postArrivalNotification(message: msg)
        if r.followerOn && !r.topic.isEmpty {
            // The final stop tears down location updates right after this
            // (finishRide), which would let iOS suspend us before the POST
            // completes. A background task keeps us alive until it lands.
            var taskID: UIBackgroundTaskIdentifier = .invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "ntfy-post") {
                UIApplication.shared.endBackgroundTask(taskID)
            }
            NtfyClient.post(topic: r.topic, message: msg) {
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }
        persist()
        pushSync(toast: "\(stop.label) reached")
        if firstUnreached(r) == -1 { finishRide() }
    }

    private func vibrate() {
        // Approximates Android's [260,120,260,120,420] waveform.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    private func postArrivalNotification(message: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "St Cecilia"
        content.body = message
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "stc.arrival.\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        center.add(req)
    }

    func pushSync(toast: String?) {
        guard let r = ride else { return }
        let payload: [String: Any] = [
            "reached": r.stops.map { $0.reached },
            "skipped": r.stops.map { $0.skipped },
            "next": firstUnreached(r)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let b64 = data.base64EncodedString()
        jsEval?("if (typeof nativeSync === 'function') { try { nativeSync('\(b64)',\(jsLiteral(toast))); } catch(e){} }")
    }

    private func jsLiteral(_ s: String?) -> String {
        guard let s = s else { return "null" }
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationTracker: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, let r = ride else { return }
        // horizontalAccuracy < 0 means invalid on iOS.
        guard loc.horizontalAccuracy >= 0 else { return }
        handleLocation(loc, accuracy: loc.horizontalAccuracy, ride: r)
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        // Ignore transient GPS errors; the next fix will come.
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if CLLocationManager.authorizationStatus() == .authorizedAlways,
           let cfg = pendingConfig {
            pendingConfig = nil
            if startRide(configJson: cfg) == "started" {
                onAutoStarted?()
                pushSync(toast: nil)
            }
        }
    }
}
