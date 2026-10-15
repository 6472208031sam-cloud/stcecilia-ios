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
    var followerOn = true
    var sound = true
    var snapDistance = 100.0
    var schedEnabled = false
    var schedOn1 = 480
    var schedOff1 = 600
    var schedOn2 = 930
    var schedOff2 = 1110
    var schedWeekdaysOnly = true
    var scheduledRide = false
    var stops: [RideStop] = []
    var lastFixTime: Date?
    var lastFixAccuracy: Double = -1
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
        followerOn = json["followerOn"] as? Bool ?? true
        sound = json["sound"] as? Bool ?? true
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
            "completed": completed,
            "completedAt": completedAt.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
            "stops": stops.map { $0.toJSON() }
        ]
    }
}

/// Persists the active ride to UserDefaults (Android: SharedPreferences).
enum RideStore {
    private static let key = "stcecilia_ride_state"

    static func save(_ ride: RideState) {
        if let data = try? JSONSerialization.data(withJSONObject: ride.toJSON()) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> RideState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stops = obj["stops"] as? [[String: Any]], !stops.isEmpty else {
            return nil
        }
        return RideState(json: obj)
    }

    static func clear() {
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
