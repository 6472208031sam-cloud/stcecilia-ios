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
    // Phase 4 ENABLE: one-stop restore recovery evaluation.
    // Armed ONLY in restore() when a persisted ride resumes after
    // process death; evaluated once (immediately for the final-stop /
    // no-established-position cases, otherwise on the first FRESH
    // fix) and writes one RECOVERY log line. On a progression verdict
    // with credit available it applies ONE silent skip of stop N
    // (verdict=advanced); it never sends ntfy for that skip.
    private var recoveryArmed = false
    private var recoveryRideId = ""
    private var recoveryNextIdx = -1
    private var recoveryFollowingIdx = -1
    // On-bus detection (AM only)
    private var checkpointProgress: [Int: Int] = [:]
    private var lastCpLogAt: Date = .distantPast
    private var onBusStop: String? = nil
    // On-bus detection checkpoints (AM only): 3 per stop at 50/100/150m
    // Format: (stopIdx, seq, lat, lng)
    private static let amCheckpoints: [(Int, Int, Double, Double)] = [
        (0, 0, 43.497995, -79.720251),
        (0, 1, 43.497681, -79.719806),
        (0, 2, 43.497368, -79.719362),
        (1, 0, 43.497841, -79.720032),
        (1, 1, 43.497527, -79.719588),
        (1, 2, 43.497214, -79.719144),
        (2, 0, 43.497267, -79.71922),
        (2, 1, 43.496935, -79.718807),
        (2, 2, 43.496498, -79.718691),
        (3, 0, 43.496583, -79.718701),
        (3, 1, 43.496377, -79.719042),
        (3, 2, 43.496341, -79.71966),
        (4, 0, 43.496396, -79.718709),
        (4, 1, 43.49636, -79.719326),
        (4, 2, 43.496326, -79.719892),
        (5, 0, 43.496357, -79.719386),
        (5, 1, 43.496323, -79.719951),
        (5, 2, 43.496179, -79.720497),
        (6, 0, 43.496286, -79.720343),
        (6, 1, 43.49592, -79.720667),
        (6, 2, 43.495513, -79.720933),
        (7, 0, 43.495831, -79.720725),
        (7, 1, 43.495425, -79.720991),
        (7, 2, 43.495124, -79.721188),
    ]

    // MARK: - Diagnostic logging (viewable from the web page's Logs panel)
    private var nativeLogs: [String] = []
    private var lastGpsLogAt: Date = .distantPast
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func nativeLog(_ cat: String, _ msg: String) {
        let ts = Self.logTimeFormatter.string(from: Date())
        nativeLogs.append("[\(ts)] [\(cat)] \(msg)")
        if nativeLogs.count > 200 { nativeLogs.removeFirst(nativeLogs.count - 200) }
    }

    /// Joined log text for the WebView via NativeBridge.getNativeLogs().
    func nativeLogsText() -> String {
        return nativeLogs.joined(separator: "\n")
    }

    func clearNativeLogs() {
        nativeLogs.removeAll()
    }

    /// ScheduleManager has no log buffer of its own; route its lines here
    /// (main-thread safe: notification callbacks arrive on other queues).
    func schedLog(_ msg: String) {
        if Thread.isMainThread {
            nativeLog("SCHED", msg)
        } else {
            DispatchQueue.main.async { [weak self] in self?.nativeLog("SCHED", msg) }
        }
    }

    /// Set by ViewController: evaluates JS in the page.
    var jsEval: ((String) -> Void)?
    /// Called when a permission-deferred ride auto-starts.
    var onAutoStarted: (() -> Void)?
    /// Tab requested by tapping a schedule notification.
    var pendingScheduledTab: String?

    /// Quiet local ride-start confirmation (first GPS fix, with
    /// accuracy). One fixed identifier, so a new ride's notification
    /// replaces the previous one instead of stacking.
    static let startNotificationID = "stc.ride.start"
    private var startNotificationPending = false
    /// Accuracy (rounded m) the posted start note currently shows;
    /// a later fix that beats it re-posts the note (same identifier).
    private var startNotificationShownAccuracy: Int? = nil

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

    // MARK: - Toronto time helpers (Phase 2)

    private var torontoCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }

    /// "yyyy-MM-dd" in Toronto — lexicographically comparable day key.
    func torontoDayKey(_ date: Date) -> String {
        let c = torontoCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Minutes since midnight in Toronto.
    func torontoMinutes(_ date: Date) -> Int {
        let c = torontoCalendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func id8(_ r: RideState) -> String {
        return String(r.rideId.prefix(8))
    }

    private func removeStartNote() {
        startNotificationPending = false
        startNotificationShownAccuracy = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.startNotificationID])
    }

    /// Teardown of the in-memory ride only (no store changes): used by
    /// reconcile / schedule-override paths after they settle the stores.
    private func teardownInMemory(_ subject: RideState) {
        guard ride === subject else { return }
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        removeStartNote()
    }

    func pushSyncIfActive() {
        if ride != nil { pushSync(toast: nil) }
    }

    // MARK: - Settings acknowledgment (Phase 2)

    private static let settingsRevKey = "stcecilia_settings_rev"
    private static let settingsAckedKey = "stcecilia_settings_acked"
    private static let settingsTupleKey = "stcecilia_settings_tuple"

    private func settingsSignature(_ cfg: RideState) -> String {
        return [String(cfg.followerOn), String(cfg.sound), cfg.myStopAm, cfg.myStopPm,
                cfg.deviceId, cfg.deviceLabel, String(cfg.schedEnabled),
                String(cfg.schedOn1), String(cfg.schedOff1), String(cfg.schedOn2),
                String(cfg.schedOff2), String(cfg.schedWeekdaysOnly)]
            .joined(separator: "|")
    }

    /// First updateConfig from the page is a handshake (accept + ack);
    /// later changes bump the revision. Unchanged tuples log nothing.
    private func acknowledgeSettings(_ cfg: RideState) {
        let d = UserDefaults.standard
        var rev = d.integer(forKey: Self.settingsRevKey)
        let acked = d.bool(forKey: Self.settingsAckedKey)
        let sig = settingsSignature(cfg)
        let stored = d.string(forKey: Self.settingsTupleKey) ?? ""
        if !acked {
            d.set(true, forKey: Self.settingsAckedKey)
            if sig != stored {
                rev += 1
                d.set(rev, forKey: Self.settingsRevKey)
                d.set(sig, forKey: Self.settingsTupleKey)
            }
            nativeLog("SET", "handshake: page settings accepted rev=\(rev)")
        } else if sig != stored {
            rev += 1
            d.set(rev, forKey: Self.settingsRevKey)
            d.set(sig, forKey: Self.settingsTupleKey)
            nativeLog("SET", "applied rev=\(rev)")
        }
    }

    // MARK: - Reconcile (Phase 2)

    /// Brings stored/in-memory state in line with the unified ride-state
    /// rules. Logs ONLY when it acts (nativeLog "RECON"). Idempotent.
    func reconcile() {
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        // (a) Stored data exists but does not decode -> quarantine it.
        if RideStore.storedDataExists(), RideStore.load() == nil {
            RideStore.clear()
            nativeLog("RECON", "quarantined corrupt state")
        }
        guard let subject = ride ?? RideStore.load() else { return }
        let inMemory = (ride != nil && ride === subject)
        // Housekeeping: an expired completed ride (>=15 min) is dropped
        // silently (moved here from statusJson).
        if subject.completed {
            if let at = subject.completedAt, now.timeIntervalSince(at) >= 15 * 60 {
                RideStore.clear()
            }
            return
        }
        if subject.ended { return }
        // Live-ride guard: a live tracked ride (in memory) skips
        // (b),(d),(e) regardless of fix age — a stationary phone may go
        // minutes between fixes while its ride is genuinely still
        // tracking. Cold state is unaffected: at launch restore()
        // reconciles with ride == nil, so inMemory is false there.
        var skipGuarded = false
        if inMemory {
            skipGuarded = true
        }
        // (b) Legacy active ride (no startedAt) -> ended record.
        if !skipGuarded, subject.startedAt == 0 {
            subject.ended = true
            subject.endedAt = nowMs
            subject.endReason = "legacy"
            subject.revision += 1
            EndedStore.save(subject)
            RideStore.clear()
            teardownInMemory(subject)
            nativeLog("SNAP", snapLogLine(ride: subject, state: "ended"))
            nativeLog("RECON", "ended legacy ride (no startedAt)")
            return
        }
        // (c) An interrupted async ending (ending==true) is finalized.
        if subject.ending {
            if firstUnreached(subject) == -1 {
                subject.ending = false
                subject.completed = true
                subject.completedAt = now
                subject.revision += 1
                RideStore.save(subject)
                nativeLog("SNAP", snapLogLine(ride: subject, state: "completed"))
            } else {
                subject.ending = false
                subject.ended = true
                subject.endedAt = nowMs
                subject.endReason = "ending-finalized"
                subject.revision += 1
                EndedStore.save(subject)
                RideStore.clear()
                teardownInMemory(subject)
                nativeLog("SNAP", snapLogLine(ride: subject, state: "ended"))
            }
            nativeLog("RECON", "finalized interrupted ending ride=\(id8(subject))")
            return
        }
        // (d) Active but every stop reached and not completed -> completed.
        if !skipGuarded, firstUnreached(subject) == -1 {
            subject.completed = true
            subject.completedAt = now
            subject.revision += 1
            RideStore.save(subject)
            nativeLog("SNAP", snapLogLine(ride: subject, state: "completed"))
            nativeLog("RECON", "classified complete ride=\(id8(subject))")
            return
        }
        // (e) Stale rule via the tab's latest schedule window.
        if !skipGuarded, subject.startedAt != 0 {
            let start = Date(timeIntervalSince1970: Double(subject.startedAt) / 1000)
            let window = ScheduleManager.shared.latestWindow(forTab: subject.tab)
            var reason: String? = nil
            if torontoDayKey(start) < torontoDayKey(now) {
                reason = "prev-day"
            } else if window.off > window.on,
                      torontoMinutes(start) <= window.off,
                      torontoMinutes(now) > window.off,
                      torontoDayKey(start) == torontoDayKey(now) {
                reason = "window-passed"
            }
            if let reason = reason {
                let rid = id8(subject)
                let tab = subject.tab
                RideStore.clear()
                teardownInMemory(subject)
                nativeLog("RECON", "discarded stale ride=\(rid) route=\(tab) reason=\(reason)")
                return
            }
        }
    }

    // MARK: - Bridge API (mirrors Android NativeBridge + TrackingService)

    /// Returns "started" / "permission_needed" / "error", exactly like Android.
    /// Phase 2 check-first start: a live ride is never wiped by a start —
    /// manual starts resume it, scheduled starts resync / re-tag / override
    /// only per the rules below; a fresh ride is created only when no live
    /// ride exists (or a scheduled start overrides a different tab).
    func startRide(configJson: String?, scheduled: Bool = false) -> String {
        nativeLog("SYS", "startRide scheduled=\(scheduled)")
        guard let configJson = configJson, !configJson.isEmpty,
              let data = configJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            nativeLog("SYS", "startRide: invalid config -> error")
            return "error"
        }
        let cfg = RideState(json: obj)
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            nativeLog("SYS", "startRide: permission_needed (requesting always)")
            pendingConfig = configJson
            manager.requestAlwaysAuthorization()
            return "permission_needed"
        case .authorizedAlways:
            break
        default:
            // denied / restricted / when-in-use: the page shows the
            // "Allow all the time" toast, same as Android.
            nativeLog("SYS", "startRide: permission_needed (denied/restricted)")
            return "permission_needed"
        }
        // Scheduled currency gate: a stale schedule event (outside
        // [on-15, off] for its tab, Toronto minutes) starts nothing.
        if scheduled {
            let window = ScheduleManager.shared.latestWindow(forTab: cfg.tab)
            let nowMin = torontoMinutes(Date())
            if nowMin < window.on - 15 || nowMin > window.off {
                nativeLog("SCHED", "stale event ignored page=\(cfg.tab)")
                pushSyncIfActive()
                return "started"
            }
        }
        reconcile()
        var override = false
        if let live = ride, !live.completed, !live.ended {
            if !scheduled {
                // Manual start over a live ride: change NOTHING, resume it.
                nativeLog("START", "live ride exists — resuming ride=\(id8(live)) (check-first)")
                beginTracking()
                pushSync(toast: nil)
                return "started"
            }
            if live.tab == cfg.tab {
                // Scheduled start for the live ride's tab: resync, except a
                // never-fixed, zero-progress, non-schedule ride is re-tagged
                // as schedule-started.
                if live.lastFixTime == nil, live.stops.allSatisfy({ !$0.reached && !$0.skipped }),
                   live.startSource != "schedule" {
                    live.startSource = "schedule"
                    live.scheduledRide = true
                    persist()
                    nativeLog("SCHED", "re-tagged startSource=schedule ride=\(id8(live))")
                }
                pushSync(toast: nil)
                return "started"
            }
            // Scheduled start for a DIFFERENT tab: end the live ride into
            // the EndedStore, tear it down, then fall through to a fresh
            // create that must NOT clear that ended record.
            let old = live
            old.ended = true
            old.endedAt = Int(Date().timeIntervalSince1970 * 1000)
            old.endReason = "schedule-override"
            old.revision += 1
            EndedStore.save(old)
            nativeLog("SNAP", snapLogLine(ride: old, state: "ended"))
            nativeLog("SCHED", "schedule override: ended ride=\(id8(old)) route=\(old.tab) reason=schedule-override")
            teardownInMemory(old)
            RideStore.clear()
            jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
            override = true
        }
        // Fresh create: state from cfg, ALL stop flags zeroed explicitly,
        // identity zeroed (in applyConfig) then stamped fresh.
        applyConfig(jsonString: configJson, keepProgress: false)
        guard let r = ride else { return "error" }
        for s in r.stops {
            s.reached = false
            s.skipped = false
        }
        // Phase 4 ENABLE: a fresh ride starts with recovery credit available.
        r.recoveryCreditAvailable = true
        r.rideId = UUID().uuidString
        r.startedAt = Int(Date().timeIntervalSince1970 * 1000)
        r.startSource = scheduled ? "schedule" : "manual"
        r.routeFingerprint = r.computeFingerprint()
        r.scheduledRide = scheduled
        if !override { EndedStore.clear() }
        persist()
        beginTracking()
        nativeLog("SYS", "startRide: started stops=\(ride?.stops.count ?? 0)")
        return "started"
    }

    /// Schedule-notification tap entry (called by ViewController's thin
    /// wrapper): currency gate first, then a scheduled check-first start;
    /// on success the page is told the ride auto-started and resynced.
    func handleScheduleTap(tab: String) -> Bool {
        reconcile()
        let window = ScheduleManager.shared.latestWindow(forTab: tab)
        let nowMin = torontoMinutes(Date())
        if nowMin < window.on - 15 || nowMin > window.off {
            nativeLog("SCHED", "stale event ignored page=\(tab)")
            pushSyncIfActive()
            return true
        }
        guard let cfg = ScheduleManager.shared.configJSON(forTab: tab),
              startRide(configJson: cfg, scheduled: true) == "started" else {
            return false
        }
        jsEval?("if (typeof nativeAutoStarted === 'function') { try { nativeAutoStarted(); } catch(e){} }")
        pushSync(toast: nil)
        return true
    }

    /// D7: skip the next unreached stop natively. Marks it reached+skipped
    /// with NO arrival side-effects (no ntfy, no sound); skipping the last
    /// unreached stop ends the ride as ENDED (reason "skip-final").
    func skipNext() {
        guard let r = ride else {
            nativeLog("SKIP", "no-op (no active ride)")
            return
        }
        guard let idx = r.stops.firstIndex(where: { !$0.reached && !$0.skipped }) else {
            nativeLog("SKIP", "no-op (no unreached stop)")
            return
        }
        r.stops[idx].reached = true
        r.stops[idx].skipped = true
        persist()
        nativeLog("SKIP", "skipped next stop \(r.stops[idx].label) ride=\(id8(r))")
        if firstUnreached(r) == -1 {
            r.ended = true
            r.endedAt = Int(Date().timeIntervalSince1970 * 1000)
            r.endReason = "skip-final"
            r.revision += 1
            EndedStore.save(r)
            RideStore.clear()
            ride = nil
            nearCount = 0
            nearTargetIdx = -1
            manager.stopUpdatingLocation()
            removeStartNote()
            nativeLog("SNAP", snapLogLine(ride: r, state: "ended"))
            jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
        } else {
            pushSync(toast: nil)
        }
    }

    func stopRide() {
        nativeLog("SYS", "stopRide")
        guard ride != nil else { return }
        startNotificationPending = false
        startNotificationShownAccuracy = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.startNotificationID])
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        RideStore.clear()
        EndedStore.clear()
        nativeLog("SNAP", snapLogLine(ride: nil, state: "none"))
        jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
    }

    func markReached() {
        guard let r = ride else { return }
        let idx = r.stops.firstIndex(where: { !$0.reached }) ?? -1
        if idx >= 0 && idx < r.stops.count {
            nativeLog("STOP", "markReached manual: \(r.stops[idx].label)")
            arrive(at: idx)
        }
    }

    func updateConfig(configJson: String?) {
        nativeLog("SYS", "updateConfig")
        guard let configJson = configJson,
              let data = configJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let cfg = RideState(json: obj)
        // Settings acknowledgment runs BEFORE anything is applied.
        acknowledgeSettings(cfg)
        // Always refresh the schedule (must survive with no active ride).
        ScheduleManager.shared.apply(config: cfg)
        if let r = ride {
            // §5: during a ride ONLY settings fields are copied into the
            // live ride — never tab/page/stops/progress/identity/
            // scheduledRide — so a page reopen can never move the route.
            r.followerOn = cfg.followerOn
            r.sound = cfg.sound
            r.myStopAm = cfg.myStopAm
            r.myStopPm = cfg.myStopPm
            r.deviceId = cfg.deviceId
            r.deviceLabel = cfg.deviceLabel
            r.topic = cfg.topic
            r.snapDistance = cfg.snapDistance
            r.schedEnabled = cfg.schedEnabled
            r.schedOn1 = cfg.schedOn1
            r.schedOff1 = cfg.schedOff1
            r.schedOn2 = cfg.schedOn2
            r.schedOff2 = cfg.schedOff2
            r.schedWeekdaysOnly = cfg.schedWeekdaysOnly
            persist()
            nativeLog("CFG", "settings applied during ride (route unchanged)")
            pushSync(toast: nil)
        }
    }

    /// Status JSON for the WebView to resync; "" when no ride is active.
    /// A recently completed ride (within 15 min) is returned with
    /// active=false so the page can show the arrived UI after a background
    /// finish. Shape mirrors Android's getStatusJson().
    func statusJson() -> String {
        reconcile()
        if let r = ride, !r.stops.isEmpty {
            return statusPayload(ride: r, active: true)
        }
        if let r = RideStore.load(), !r.stops.isEmpty, r.completed {
            if let at = r.completedAt, Date().timeIntervalSince(at) < 15 * 60 {
                return statusPayload(ride: r, active: false)
            }
            // Expired (reconcile's housekeeping normally clears this first).
            RideStore.clear()
        }
        if let e = EndedStore.load(), !e.stops.isEmpty, e.ended {
            return statusPayload(ride: e, active: false)
        }
        return ""
    }

    private func statusPayload(ride r: RideState, active: Bool) -> String {
        var payload: [String: Any] = [
            "active": active,
            "completed": r.completed,
            "page": r.page,
            "tab": r.tab,
            "reached": r.stops.map { $0.reached },
            "skipped": r.stops.map { $0.skipped },
            "next": firstUnreached(r),
            "total": r.stops.count
        ]
        if r.ended {
            payload["ended"] = true
        }
        // on-bus pill for driver map: poll path must include it (like pushSync).
        if active, let obs = onBusStop {
            payload["onBus"] = obs
        }
        // Phase 1 (shadow mode): the unified snapshot rides alongside the
        // legacy fields. Nothing reads it yet; the GUI still uses the
        // legacy fields above.
        payload["snapshot"] = buildSnapshot(ride: r, active: active)
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Phase 1 unified ride-state snapshot (schema 1), built fresh from
    /// the ride being served on every status call. Pure read: no state
    /// changes. Identity fields are null until stamped (legacy rides).
    private func buildSnapshot(ride r: RideState, active: Bool) -> [String: Any] {
        var rideIdVal: Any = NSNull()
        if !r.rideId.isEmpty { rideIdVal = r.rideId }
        var startedAtVal: Any = NSNull()
        if r.startedAt != 0 { startedAtVal = r.startedAt }
        var startSourceVal: Any = NSNull()
        if !r.startSource.isEmpty { startSourceVal = r.startSource }
        var fingerprintVal: Any = NSNull()
        if !r.routeFingerprint.isEmpty { fingerprintVal = r.routeFingerprint }
        var nextIndex = -1
        var nextLabelVal: Any = NSNull()
        for i in 0..<r.stops.count {
            if !r.stops[i].reached && !r.stops[i].skipped {
                nextIndex = i
                nextLabelVal = r.stops[i].label
                break
            }
        }
        var onBusVal: Any = NSNull()
        if active, let obs = onBusStop { onBusVal = obs }
        // lastFix only when the served ride is the live tracker ride.
        var lastFixVal: Any = NSNull()
        if active, self.ride === r, let t = r.lastFixTime {
            lastFixVal = ["at": Int(t.timeIntervalSince1970 * 1000),
                          "acc": r.lastFixAccuracy] as [String: Any]
        }
        var healthVal: Any = NSNull()
        if active {
            if let t = r.lastFixTime, Date().timeIntervalSince(t) <= 30 {
                healthVal = "live"
            } else {
                healthVal = "waiting"
            }
        }
        var snap: [String: Any] = [
            "schema": 1,
            "rideId": rideIdVal,
            "revision": r.revision,
            "state": r.ended ? "ended" : (active ? "active" : "completed"),
            "startedAt": startedAtVal,
            "startSource": startSourceVal,
            "route": [
                "page": r.page,
                "tab": r.tab,
                "fingerprint": fingerprintVal,
                "stops": r.stops.map { s in
                    ["label": s.label, "name": s.name, "lat": s.lat, "lng": s.lng,
                     "reached": s.reached, "skipped": s.skipped] as [String: Any]
                }
            ] as [String: Any],
            "progress": [
                "reached": r.stops.filter { $0.reached }.count,
                "skipped": r.stops.filter { $0.skipped }.count,
                "total": r.stops.count,
                "nextIndex": nextIndex,
                "nextLabel": nextLabelVal
            ] as [String: Any],
            "onBus": onBusVal,
            "lastFix": lastFixVal,
            "schedule": [
                "enabled": r.schedEnabled,
                "on1": r.schedOn1,
                "off1": r.schedOff1,
                "on2": r.schedOn2,
                "off2": r.schedOff2,
                "weekdaysOnly": r.schedWeekdaysOnly
            ] as [String: Any],
            "settings": [
                "followerOn": r.followerOn,
                "sound": r.sound,
                "myStopAm": r.myStopAm,
                "myStopPm": r.myStopPm,
                "deviceId": r.deviceId,
                "settingsRev": UserDefaults.standard.integer(forKey: Self.settingsRevKey),
                "settingsAcked": UserDefaults.standard.bool(forKey: Self.settingsAckedKey)
            ] as [String: Any],
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
            "health": healthVal
        ]
        if r.ended {
            snap["endedAt"] = r.endedAt
            snap["endReason"] = r.endReason
        }
        return snap
    }

    /// Phase 1 SNAP log line (shadow mode). Format:
    /// rev=<n> state=<active|completed|none> route=<page|-> fp=<fp8|->
    /// ride=<id8|-> startedAt=<ms|-> src=<source|-> reached=<n>/<total>
    /// next=<label|->
    private func snapLogLine(ride r: RideState?, state: String) -> String {
        guard let r = r else {
            return "rev=0 state=none route=- fp=- ride=- startedAt=- src=- reached=0/0 next=-"
        }
        let reachedCount = r.stops.filter { $0.reached }.count
        var nextLabel = "-"
        for s in r.stops where !s.reached && !s.skipped {
            nextLabel = s.label
            break
        }
        let route = r.page.isEmpty ? "-" : r.page
        let fp = r.routeFingerprint.isEmpty ? "-" : String(r.routeFingerprint.prefix(8))
        let rid = r.rideId.isEmpty ? "-" : String(r.rideId.prefix(8))
        let started = r.startedAt == 0 ? "-" : "\(r.startedAt)"
        let src = r.startSource.isEmpty ? "-" : r.startSource
        return "rev=\(r.revision) state=\(state) route=\(route) fp=\(fp) ride=\(rid) startedAt=\(started) src=\(src) reached=\(reachedCount)/\(r.stops.count) next=\(nextLabel)"
    }

    // MARK: - Phase 4 recovery evaluation (ENABLED)

    /// First stop at or after `idx` that is neither reached nor skipped,
    /// or -1 when there is none.
    private func recoveryUnreachedIndex(_ r: RideState, from idx: Int) -> Int {
        var i = idx
        while i < r.stops.count {
            if !r.stops[i].reached && !r.stops[i].skipped { return i }
            i += 1
        }
        return -1
    }

    /// Arm the one-shot recovery evaluation for a ride restored in
    /// restore(). Judge order at restore: (a) established-position
    /// guard — if NO stop is already passed (reached or skipped) the
    /// verdict is logged immediately here (no-established-position)
    /// and nothing arms; (b) else the final-stop case (next stop N
    /// has no following unreached stop) logs immediately here and
    /// never arms; otherwise the evaluation arms for the first
    /// fresh fix.
    private func armRecoveryEvaluation(for r: RideState) {
        guard !r.completed, !r.ended else { return }
        let nextIdx = recoveryUnreachedIndex(r, from: 0)
        guard nextIdx >= 0 else { return }
        let followingIdx = recoveryUnreachedIndex(r, from: nextIdx + 1)
        // (a) Established-position guard: at least one stop must
        // already be passed at restore.
        let hasPassed = r.stops.contains { $0.reached || $0.skipped }
        guard hasPassed else {
            let followingLabel = followingIdx >= 0 ? r.stops[followingIdx].label : "-"
            nativeLog("RECOVERY", "verdict=would-not ride=\(id8(r)) route=\(r.tab) next=\(r.stops[nextIdx].label) following=\(followingLabel) distNext=-1 distFollowing=-1 acc=-1 reason=no-established-position fixSource=none")
            return
        }
        // (b) Final-stop case.
        guard followingIdx >= 0 else {
            nativeLog("RECOVERY", "verdict=would-not ride=\(id8(r)) route=\(r.tab) next=\(r.stops[nextIdx].label) following=- distNext=-1 distFollowing=-1 acc=-1 reason=final-stop fixSource=none")
            return
        }
        recoveryArmed = true
        recoveryRideId = r.rideId
        recoveryNextIdx = nextIdx
        recoveryFollowingIdx = followingIdx
    }

    /// Evaluate the armed recovery check once, on the first FRESH
    /// fix the resumed tracker processes. Called only from
    /// didUpdateLocations, before the invalid-accuracy guard, so a
    /// poor/invalid first fresh fix still logs (poor-accuracy).
    /// Freshness: a fix whose own CLLocation.timestamp is more than
    /// 30s old is IGNORED — the evaluation stays armed and waits for
    /// the first fresh fix. Disarms before logging/applying so it
    /// can fire exactly once. On progression with credit available
    /// it APPLIES one silent skip of stop N (verdict=advanced) and
    /// returns; didUpdateLocations then continues processing this
    /// same fix through handleLocation against the NEW next stop.
    private func evaluateRecoveryIfArmed(loc: CLLocation, ride r: RideState) {
        guard recoveryArmed else { return }
        // Fix freshness (<=30s old): stale cached fixes are ignored
        // and the evaluation stays armed — checked BEFORE disarming.
        guard Date().timeIntervalSince(loc.timestamp) <= 30 else { return }
        let armedRideId = recoveryRideId
        let nextIdx = recoveryNextIdx
        let followingIdx = recoveryFollowingIdx
        recoveryArmed = false
        recoveryRideId = ""
        recoveryNextIdx = -1
        recoveryFollowingIdx = -1
        // Only the restored ride itself qualifies — a different ride
        // started later in the same process never inherits the arm.
        guard r.rideId == armedRideId else { return }
        guard nextIdx >= 0, followingIdx >= 0,
              nextIdx < r.stops.count, followingIdx < r.stops.count else { return }
        let nextStop = r.stops[nextIdx]
        let followingStop = r.stops[followingIdx]
        let distNext = Int(loc.distance(from: CLLocation(latitude: nextStop.lat, longitude: nextStop.lng)))
        let distFollowing = Int(loc.distance(from: CLLocation(latitude: followingStop.lat, longitude: followingStop.lng)))
        let acc = Int(loc.horizontalAccuracy)
        var verdict: String
        var reason: String
        if loc.horizontalAccuracy < 0 || acc > 100 {
            verdict = "would-not"
            reason = "poor-accuracy"
        } else if distNext - distFollowing >= 20 {
            if !r.recoveryCreditAvailable {
                // Progression judged but the one credit is spent:
                // log would-advance/credit-spent, apply NOTHING
                // (the one-shot is still consumed — disarmed above).
                verdict = "would-advance"
                reason = "credit-spent"
            } else if recoveryUnreachedIndex(r, from: 0) != nextIdx
                        || r.stops[followingIdx].reached || r.stops[followingIdx].skipped {
                // Safety re-check at apply time: N must still be the
                // first unpassed stop and the captured following stop
                // must still be unpassed. If not, do NOT apply (this
                // is a deviation from the armed state) — log the
                // unapplied progression verdict.
                verdict = "would-advance"
                reason = "progression"
            } else {
                // APPLY the one-stop advance. The marking is exactly
                // skipNext()'s core marking (LocationTracker.skipNext:
                // reached=true + skipped=true, then persist) inlined —
                // skipNext() itself is NOT called, so its skip-final
                // ENDED branch can never fire here; it also cannot
                // apply on the merits, because the captured following
                // stop was just re-verified unpassed, so a stop still
                // remains after N. Passed-but-silent: arrive() is not
                // called, so there is NO arrival popup/notification,
                // NO arrival ntfy, NO My Stop waiting/got-off event
                // and NO on-bus synthesis for N — only the two flag
                // assignments below, the credit spend, and persist()
                // (revision bump + RideStore save + SNAP line), plus
                // a silent pushSync (toast=nil) like skipNext's
                // non-final branch so the page mirrors the snapshot.
                r.stops[nextIdx].reached = true
                r.stops[nextIdx].skipped = true
                // Spend the ride's one recovery credit (persisted
                // with the ride state by the persist() below).
                r.recoveryCreditAvailable = false
                persist()
                pushSync(toast: nil)
                verdict = "advanced"
                reason = "progression"
            }
        } else {
            verdict = "would-not"
            reason = "no-progression"
        }
        nativeLog("RECOVERY", "verdict=\(verdict) ride=\(id8(r)) route=\(r.tab) next=\(nextStop.label) following=\(followingStop.label) distNext=\(distNext) distFollowing=\(distFollowing) acc=\(acc) reason=\(reason) fixSource=first-fix")
    }

    /// Resume a persisted ride on launch (mirrors Android's START_STICKY restart).
    /// A completed ride is for display only — never resume it as an active ride.
    func restore() {
        // Phase 2: reconcile the stored state before anything resumes it —
        // a stale / legacy / interrupted-ending ride never comes back live.
        reconcile()
        guard let r = RideStore.load(), !r.stops.isEmpty, !r.completed else { return }
        ride = r
        // Phase 4 ENABLE: arm the one-shot recovery evaluation
        // exactly here — restore() is launch-only, so this arm is
        // inherently process-death-only. Never arm anywhere else.
        armRecoveryEvaluation(for: r)
        // No stamping here: identity loads with the state (a legacy state
        // has none and keeps none).
        nativeLog("SNAP", snapLogLine(ride: r, state: "active"))
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
            // Same ride continuing (Phase 1): identity carries over too.
            cfg.rideId = r.rideId
            cfg.startedAt = r.startedAt
            cfg.startSource = r.startSource
            cfg.routeFingerprint = r.routeFingerprint
            cfg.revision = r.revision
            // Same ride continuing: its recovery credit carries over.
            cfg.recoveryCreditAvailable = r.recoveryCreditAvailable
        } else {
            // No merge: identity must not leak in from the incoming JSON
            // (a stored schedule config is serialized via toJSON and can
            // carry a previous ride's identity). startRide stamps a fresh
            // identity when it finds rideId empty; restore() never comes
            // through here.
            cfg.rideId = ""
            cfg.startedAt = 0
            cfg.startSource = ""
            cfg.routeFingerprint = ""
            cfg.revision = 0
            // No merge: recovery credit must not leak in from the
            // incoming JSON either — a fresh ride has credit available.
            cfg.recoveryCreditAvailable = true
        }
        ride = cfg
        ScheduleManager.shared.apply(config: cfg)
        persist()
    }

    private func beginTracking() {
        guard ride != nil else { return }
        nearCount = 0
        nearTargetIdx = -1
        checkpointProgress.removeAll()
        lastCpLogAt = .distantPast
        onBusStop = nil
        startNotificationPending = true
        startNotificationShownAccuracy = nil
        persist()
        manager.startUpdatingLocation()
    }

    private func persist() {
        if let r = ride {
            r.revision += 1
            RideStore.save(r)
            nativeLog("SNAP", snapLogLine(ride: r, state: r.completed ? "completed" : "active"))
        }
    }

    private func firstUnreached(_ r: RideState) -> Int {
        for i in 0..<r.stops.count {
            if !r.stops[i].reached { return i }
        }
        return -1
    }

    private func finishRide() {
        nativeLog("SYS", "finishRide")
        startNotificationPending = false
        startNotificationShownAccuracy = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.startNotificationID])
        // Keep the state marked completed (with a timestamp) instead of
        // deleting it, so the WebView can show the arrived UI on resume.
        if let r = ride {
            r.completed = true
            r.completedAt = Date()
            r.revision += 1
            RideStore.save(r)
            nativeLog("SNAP", snapLogLine(ride: r, state: "completed"))
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

        // Throttled GPS log for the Logs panel (1/sec max).
        let now = Date()
        if now.timeIntervalSince(lastGpsLogAt) >= 1.0 {
            lastGpsLogAt = now
            nativeLog("GPS", String(format: "fix lat=%.6f lng=%.6f acc=%dm", lat, lng, Int(accuracy)))
        }

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
            // Safeguard: never snap more than 3 stops ahead on startup,
            // UNLESS high-accuracy (<=30m). Precise fix near far stop = real
            // mid-route boarding; coarse fix jumping far = cold-GPS glitch.
            let maxSkip = 3
            let highAccuracy = accuracy <= 30
            if !highAccuracy && best > idx && (best - idx) > maxSkip {
                best = -1
            }
            if best > idx && bestDist <= r.snapDistance {
                nativeLog("STOP", "Snap forward \(idx)->\(best) (\(r.stops[best].label)) dist=\(Int(bestDist))m")
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
            arrive(at: idx, genuineGps: true)
        } else if distance <= 15 && accuracy <= 150 {
            // Very close to the pin — trust it even with moderate accuracy.
            arrive(at: idx, genuineGps: true)
        } else if accuracy <= 200 && distance <= stop.radius + accuracy {
            // Tier 2: poor accuracy (phone pocketed) — 3 consecutive fixes
            // near the stop confirm the arrival. A GPS jump won't persist.
            if nearTargetIdx != idx { nearTargetIdx = idx; nearCount = 0 }
            nearCount += 1
            if nearCount >= 3 {
                nearCount = 0
                nearTargetIdx = -1
                arrive(at: idx, genuineGps: true)
            }
        } else {
            nearCount = 0
            nearTargetIdx = -1
        }

        // Ride-start confirmation: once per ride, on the first fix, after
        // snap/arrival processing so the counts reflect this fix.
        if startNotificationPending {
            startNotificationPending = false
            if ride != nil { postStartNotification(accuracy: accuracy, ride: r) }
        } else if ride != nil, let shown = startNotificationShownAccuracy,
                  Int(accuracy.rounded()) < shown {
            // Accuracy beat what the start note shows: quietly re-post
            // (same identifier) so the note tracks the best fix, like
            // Android's live banner. No threshold \u2014 any improvement.
            postStartNotification(accuracy: accuracy, ride: r)
        }

        // On-bus detection (AM only)
        checkOnBusCheckpoints(lat: lat, lng: lng, accuracy: accuracy, ride: r)
    }

    private func checkOnBusCheckpoints(lat: Double, lng: Double, accuracy: Double, ride r: RideState) {
        guard r.page == "am" else { return }
        guard !Self.amCheckpoints.isEmpty else {
            nativeLog("BUS-DETECT", "No checkpoints loaded!")
            return
        }
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastCpLogAt) >= 10.0
        for (stopIdx, seq, cpLat, cpLng) in Self.amCheckpoints {
            guard stopIdx < r.stops.count else { continue }
            let stop = r.stops[stopIdx]
            guard stop.reached else { continue }
            let prog = checkpointProgress[stopIdx] ?? 0
            guard prog == seq else { continue }
            let d = haversine(lat1: lat, lon1: lng, lat2: cpLat, lon2: cpLng)
            if shouldLog {
                nativeLog("BUS-DETECT", "Stop \(stop.label) cp\(seq+1)/3: \(Int(d))m away (need <=50m), acc=\(Int(accuracy))m")
            }
            if d <= 50 && accuracy <= 100 {
                checkpointProgress[stopIdx] = seq + 1
                nativeLog("BUS-DETECT", "Stop \(stop.label) checkpoint \(seq+1)/3 HIT (\(Int(d))m)")
                if seq == 2 && stopIdx + 1 < r.stops.count {
                    let next = r.stops[stopIdx + 1]
                    let devTag = r.deviceId.isEmpty ? "" : " [\(r.deviceId)]" + (r.deviceLabel.isEmpty ? "" : " (\(r.deviceLabel))")
                    let msg = "\u{1F4F1}\(devTag) on bus, heading to \(next.label)."
                    if r.followerOn && !r.topic.isEmpty {
                        nativeLog("NTFY", "Sending on-bus: \(msg)")
                        NtfyClient.post(topic: r.topic, message: msg) { }
                    } else {
                        nativeLog("NTFY", "Suppressed on-bus (follower alerts off): \(msg)")
                    }
                    onBusStop = next.label
                    pushSync(toast: nil)
                }
            }
        }
        if shouldLog { lastCpLogAt = now }
    }

    /// `genuineGps` is true ONLY for the three arrival call sites in
    /// handleLocation (a real GPS fix in normal sequential processing).
    /// markReached() calls with the default false; skipNext(),
    /// snap-forward and the recovery advance never call arrive() at all.
    private func arrive(at idx: Int, genuineGps: Bool = false) {
        guard let r = ride, idx < r.stops.count else { return }
        nearCount = 0
        nearTargetIdx = -1
        onBusStop = nil
        let stop = r.stops[idx]
        stop.reached = true
        // Phase 4 ENABLE: a genuine GPS arrival REGAINS the ride's
        // recovery credit (persisted by this function's persist()
        // below). No other marking path regains it.
        if genuineGps { r.recoveryCreditAvailable = true }
        let isFinal = idx == r.stops.count - 1
        if r.sound { AlertPlayer.shared.play() }
        vibrate()
        // My Stop format: "📱 [X##] waiting at Stop 1: Mia." (AM) / "got off at" (PM)
        // Regular: "🚌 [X##] at Stop 2: Walking."
        let myStopLabel = (r.tab == "pm") ? r.myStopPm : r.myStopAm
        // stop.label is like "Stop 1: Mia" — extract just the "1" or "I"
        var labelPart = stop.label
        if labelPart.hasPrefix("Stop ") { labelPart = String(labelPart.dropFirst(5)) }
        if let colonIdx = labelPart.firstIndex(of: ":") { labelPart = String(labelPart[..<colonIdx]).trimmingCharacters(in: .whitespaces) }
        // Also handle " (1)" suffix for PM like "Stop I (1)"
        if let parenIdx = labelPart.firstIndex(of: "(") { labelPart = String(labelPart[..<parenIdx]).trimmingCharacters(in: .whitespaces) }
        let isMyStop = !myStopLabel.isEmpty && myStopLabel == labelPart
        nativeLog("STOP", "Arrival: \(stop.label) myStop=\(isMyStop) final=\(isFinal)")
        // Per spec: device ID after emoji, e.g. "🚌 [A82] at Stop 1: Mia."
        // stop.label is like "Stop 1: Mia" (already includes name)
        let devTag = r.deviceId.isEmpty ? "" : " [" + r.deviceId + "]" + (r.deviceLabel.isEmpty ? "" : " (" + r.deviceLabel + ")")
        let msg: String
        let gotOff = isMyStop && r.tab == "pm"
        if isMyStop {
            msg = (r.tab == "pm")
                ? "📱\(devTag) got off at \(stop.label)."
                : "📱\(devTag) waiting at \(stop.label)."
        } else if isFinal {
            msg = "🚌\(devTag) at \(stop.label). Route complete."
        } else {
            msg = "🚌\(devTag) at \(stop.label)."
        }
        postArrivalNotification(message: msg)
        if r.followerOn && !r.topic.isEmpty {
            // The final stop tears down location updates right after this
            // (finishRide), which would let iOS suspend us before the POST
            // completes. A background task keeps us alive until it lands.
            var taskID: UIBackgroundTaskIdentifier = .invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "ntfy-post") {
                UIApplication.shared.endBackgroundTask(taskID)
            }
            let fullMsg = msg // device ID already in message per spec
            NtfyClient.post(topic: r.topic, message: fullMsg) { [weak self] in
                DispatchQueue.main.async { self?.nativeLog("NTFY", "Sent: \(fullMsg)") }
                UIApplication.shared.endBackgroundTask(taskID)
                // Auto-stop on "got off" (PM My Stop): journey done.
                // §7 async ending: the got-off post has landed, so mark the
                // ride ending=true BEFORE the off-bus post; if the app dies
                // mid-chain, reconcile() finalizes the interrupted ending.
                if gotOff {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        r.ending = true
                        if self.ride === r {
                            self.persist()
                        } else {
                            r.revision += 1
                            RideStore.save(r)
                        }
                        let endingRideId = r.rideId
                        let endingRevision = r.revision
                        let offMsg = "📱\(devTag) off bus. Tracking stopped."
                        var offTaskID: UIBackgroundTaskIdentifier = .invalid
                        offTaskID = UIApplication.shared.beginBackgroundTask(withName: "ntfy-offbus") {
                            UIApplication.shared.endBackgroundTask(offTaskID)
                        }
                        NtfyClient.post(topic: r.topic, message: offMsg) { [weak self] in
                            DispatchQueue.main.async { self?.nativeLog("NTFY", "Sent: \(offMsg)") }
                            UIApplication.shared.endBackgroundTask(offTaskID)
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                // Finalize ENDED only if the live ride is
                                // still exactly the one that was ending.
                                guard let cur = self.ride, cur === r,
                                      cur.rideId == endingRideId,
                                      cur.revision == endingRevision else {
                                    self.nativeLog("SYS", "got-off finalize skipped (state changed)")
                                    return
                                }
                                cur.ending = false
                                cur.ended = true
                                cur.endedAt = Int(Date().timeIntervalSince1970 * 1000)
                                cur.endReason = "got-off"
                                cur.revision += 1
                                EndedStore.save(cur)
                                RideStore.clear()
                                self.ride = nil
                                self.nearCount = 0
                                self.nearTargetIdx = -1
                                self.manager.stopUpdatingLocation()
                                self.removeStartNote()
                                self.nativeLog("SNAP", self.snapLogLine(ride: cur, state: "ended"))
                                self.jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
                            }
                        }
                    }
                }
            }
        } else {
            nativeLog("NTFY", "skipped followerOn=\(r.followerOn) topicSet=\(!r.topic.isEmpty)")
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

    /// Quiet (no sound) local confirmation that tracking started, posted
    /// on the first GPS fix so it can include the real accuracy — the iOS
    /// counterpart of Android's foreground-service notification line.
    /// Local only: never sent to ntfy (follower formats stay untouched).
    private func postStartNotification(accuracy: Double, ride r: RideState) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "St Cecilia"
        let route = r.tab == "pm" ? "PM" : "AM"
        let reached = r.stops.filter { $0.reached }.count
        var body = "Tracking started — \(route) route · Stop \(reached) of \(r.stops.count) · ±\(Int(accuracy.rounded()))m"
        let next = firstUnreached(r)
        if next >= 0 { body += " · Next: \(r.stops[next].label)" }
        content.body = body
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: Self.startNotificationID,
            content: content, trigger: nil)
        let isUpdate = startNotificationShownAccuracy != nil
        center.add(req) { error in
            if let error = error {
                self.nativeLog("SYS", "ride-start notification FAILED: \(error.localizedDescription)")
            } else {
                self.startNotificationShownAccuracy = Int(accuracy.rounded())
                self.nativeLog("SYS", "ride-start notification \(isUpdate ? "updated" : "posted"): \(body)")
            }
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
        var payload: [String: Any] = [
            "reached": r.stops.map { $0.reached },
            "skipped": r.stops.map { $0.skipped },
            "next": firstUnreached(r)
        ]
        if let obs = onBusStop {
            payload["onBus"] = obs
            nativeLog("BUS-DETECT", "Sync includes onBus: \(obs)")
        }
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
        // Phase 4 ENABLE: evaluate the armed restore-recovery
        // check on this first fresh fix, before the invalid-accuracy
        // guard below (an invalid/poor first fresh fix still logs
        // poor-accuracy). If an advance is applied, handleLocation
        // below continues processing this same fix against the NEW
        // next stop. handleLocation sets lastFixTime right after.
        evaluateRecoveryIfArmed(loc: loc, ride: r)
        // horizontalAccuracy < 0 means invalid on iOS.
        guard loc.horizontalAccuracy >= 0 else { return }
        handleLocation(loc, accuracy: loc.horizontalAccuracy, ride: r)
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        // Ignore transient GPS errors; the next fix will come.
        nativeLog("GPS", "error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        nativeLog("SYS", "auth changed: \(CLLocationManager.authorizationStatus().rawValue)")
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
