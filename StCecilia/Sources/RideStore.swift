import Foundation

/// One bus stop on the route.
final class RideStop {
    var number: Int
    var label: String
    var name: String
    var lat: Double
    var lng: Double
    var radius: Double
    var acc: Double?          // per-stop accuracy limit; nil -> 50 m default
    var reached = false
    var skipped = false

    init(json: [String: Any], index: Int) {
        number = json["number"] as? Int ?? (index + 1)
        label = json["label"] as? String ?? "Stop \(index + 1)"
        name = json["name"] as? String ?? ""
        lat = json["lat"] as? Double ?? 0
        lng = json["lng"] as? Double ?? 0
        radius = json["radius"] as? Double ?? 30
        if let a = json["acc"] as? Double {
            acc = a
        } else if let a = json["acc"] as? Int {
            acc = Double(a)
        }
        reached = json["reached"] as? Bool ?? false
        skipped = json["skipped"] as? Bool ?? false
    }

    func toJSON() -> [String: Any] {
        var d: [String: Any] = [
            "number": number,
            "label": label,
            "name": name,
            "lat": lat,
            "lng": lng,
            "radius": radius,
            "reached": reached,
            "skipped": skipped
        ]
        d["acc"] = acc ?? NSNull()
        return d
    }
}

/// Full ride config, mirroring the JSON the web page sends via
/// NativeBridge.startRide() (same shape as the Android app).
final class RideState {
    var page = "am"
    var tab = "am"
    var topic = ""
    var deviceId = ""
    var deviceLabel = ""
    var myStopAm = ""
    var myStopPm = ""
    var followerOn = true
    var sound = false
    var snapDistance = 100.0
    var schedEnabled = false
    var schedOn1 = 480
    var schedOff1 = 600
    var schedOn2 = 930
    var schedOff2 = 1110
    var schedWeekdaysOnly = true
    var scheduledRide = false
    var stops: [RideStop] = []
    // Unified ride-state identity (Phase 1, shadow mode): stamped fresh at
    // ride start, carried across applyConfig progress merges, persisted
    // with the ride. Legacy states have none and keep none.
    var rideId = ""
    var startedAt: Int = 0          // epoch milliseconds
    var startSource = ""            // "manual" / "schedule"
    var routeFingerprint = ""
    var revision = 0
    var lastFixTime: Date?
    var lastFixAccuracy: Double = -1
    // Unified ride-state Phase 2: terminal "ended" marker (distinct from
    // completed) and the async-ending flag set while a multi-step ending
    // (got-off chain) is in flight. Round-tripped like the identity fields.
    var ended = false
    var endedAt: Int = 0            // epoch milliseconds
    var endReason = ""
    var ending = false
    /// Set when finishRide() completes the route. The persisted state is
    /// kept (not deleted) so the WebView can show the arrived UI on resume.
    var completed = false
    var completedAt: Date?

    init() {}

    init(json: [String: Any]) {
        page = json["page"] as? String ?? "am"
        tab = json["tab"] as? String ?? "am"
        topic = json["topic"] as? String ?? ""
        deviceId = json["deviceId"] as? String ?? ""
        deviceLabel = json["deviceLabel"] as? String ?? ""
        if let ms = json["myStop"] as? [String: Any] {
            myStopAm = ms["am"] as? String ?? ""
            myStopPm = ms["pm"] as? String ?? ""
        }
        followerOn = json["followerOn"] as? Bool ?? true
        sound = json["sound"] as? Bool ?? false
        if let d = json["snapDistance"] as? Double {
            snapDistance = d
        } else if let i = json["snapDistance"] as? Int {
            snapDistance = Double(i)
        }
        schedEnabled = json["schedEnabled"] as? Bool ?? false
        schedOn1 = json["schedOn1"] as? Int ?? 480
        schedOff1 = json["schedOff1"] as? Int ?? 600
        schedOn2 = json["schedOn2"] as? Int ?? 930
        schedOff2 = json["schedOff2"] as? Int ?? 1110
        schedWeekdaysOnly = json["schedWeekdaysOnly"] as? Bool ?? true
        scheduledRide = json["scheduledRide"] as? Bool ?? false
        rideId = json["rideId"] as? String ?? ""
        if let v = json["startedAt"] as? Int {
            startedAt = v
        } else if let v = json["startedAt"] as? Double {
            startedAt = Int(v)
        }
        startSource = json["startSource"] as? String ?? ""
        routeFingerprint = json["routeFingerprint"] as? String ?? ""
        if let v = json["revision"] as? Int {
            revision = v
        } else if let v = json["revision"] as? Double {
            revision = Int(v)
        }
        ended = json["ended"] as? Bool ?? false
        if let v = json["endedAt"] as? Int {
            endedAt = v
        } else if let v = json["endedAt"] as? Double {
            endedAt = Int(v)
        }
        endReason = json["endReason"] as? String ?? ""
        ending = json["ending"] as? Bool ?? false
        completed = json["completed"] as? Bool ?? false
        if let ms = json["completedAt"] as? Double {
            completedAt = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = json["completedAt"] as? Int {
            completedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        if let arr = json["stops"] as? [[String: Any]] {
            stops = arr.enumerated().map { RideStop(json: $0.element, index: $0.offset) }
        }
    }

    func toJSON() -> [String: Any] {
        return [
            "page": page,
            "tab": tab,
            "topic": topic,
            "deviceId": deviceId,
            "deviceLabel": deviceLabel,
            "myStop": ["am": myStopAm, "pm": myStopPm],
            "followerOn": followerOn,
            "sound": sound,
            "snapDistance": snapDistance,
            "schedEnabled": schedEnabled,
            "schedOn1": schedOn1,
            "schedOff1": schedOff1,
            "schedOn2": schedOn2,
            "schedOff2": schedOff2,
            "schedWeekdaysOnly": schedWeekdaysOnly,
            "scheduledRide": scheduledRide,
            "rideId": rideId,
            "startedAt": startedAt,
            "startSource": startSource,
            "routeFingerprint": routeFingerprint,
            "revision": revision,
            "ended": ended,
            "endedAt": endedAt,
            "endReason": endReason,
            "ending": ending,
            "completed": completed,
            "completedAt": completedAt.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
            "stops": stops.map { $0.toJSON() }
        ]
    }

    /// Route fingerprint (must match Android exactly): FNV-1a 64-bit over
    /// the UTF-8 bytes of page + one "label|name|lat6|lng6" line per stop,
    /// lines joined by "\n", rendered as 16 lowercase hex digits.
    func computeFingerprint() -> String {
        var lines: [String] = [page]
        for s in stops {
            lines.append(s.label + "|" + s.name + "|"
                + String(format: "%.6f", s.lat) + "|"
                + String(format: "%.6f", s.lng))
        }
        var h: UInt64 = 14695981039346656037
        for b in lines.joined(separator: "\n").utf8 {
            h ^= UInt64(b)
            h &*= 1099511628211
        }
        return String(format: "%016llx", h)
    }
}

/// Persists the active ride to an atomically-written file in Application
/// Support (Phase 1 durability move off UserDefaults). Loads fall back to
/// the legacy UserDefaults value written by older builds when no file
/// exists yet, so a ride in progress during the upgrade still restores.
/// clear() removes both.
enum RideStore {
    private static let key = "stcecilia_ride_state"

    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) else { return nil }
        return dir.appendingPathComponent(key + ".json")
    }

    static func save(_ ride: RideState) {
        guard let data = try? JSONSerialization.data(withJSONObject: ride.toJSON()),
              let url = fileURL else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> RideState? {
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decode(data)
        }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> RideState? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stops = obj["stops"] as? [[String: Any]], !stops.isEmpty else {
            return nil
        }
        return RideState(json: obj)
    }

    static func clear() {
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// True when persisted bytes exist (file or legacy UserDefaults),
    /// even if they no longer decode — reconcile() quarantines that case.
    static func storedDataExists() -> Bool {
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        return UserDefaults.standard.data(forKey: key) != nil
    }
}

/// Persists the most recent ENDED ride (Phase 2), same atomic-file pattern
/// as RideStore. An ended ride is terminal but not completed: statusJson()
/// serves it so the page can render the ended snapshot until a fresh ride
/// starts (fresh starts clear it) or stopRide() clears it.
enum EndedStore {
    private static let key = "stcecilia_ended_state"

    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) else { return nil }
        return dir.appendingPathComponent(key + ".json")
    }

    static func save(_ ride: RideState) {
        guard let data = try? JSONSerialization.data(withJSONObject: ride.toJSON()),
              let url = fileURL else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> RideState? {
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decode(data)
        }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> RideState? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stops = obj["stops"] as? [[String: Any]], !stops.isEmpty else {
            return nil
        }
        return RideState(json: obj)
    }

    static func clear() {
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6371000.0
    let dLat = (lat2 - lat1) * .pi / 180.0
    let dLon = (lon2 - lon1) * .pi / 180.0
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0)
        * sin(dLon / 2) * sin(dLon / 2)
    return 2 * R * asin(sqrt(a))
}
