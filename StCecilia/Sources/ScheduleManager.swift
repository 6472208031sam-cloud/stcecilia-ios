import Foundation
import UserNotifications

/// Tracking schedule, ported from Android's ScheduleManager/ScheduleReceiver.
///
/// iOS LIMITATION (honest): iOS does not allow exact background execution
/// like Android's setAlarmClock(). An iOS app cannot wake itself up at 8:00 AM
/// and start GPS tracking with the phone locked. The closest iOS equivalent
/// is a local notification at the configured on-time saying "Tap to start
/// tracking" — tapping it opens the app, which then auto-starts the ride for
/// the right tab. That is what this class implements.
final class ScheduleManager {
    static let shared = ScheduleManager()

    private let center = UNUserNotificationCenter.current()
    private let toronto = TimeZone(identifier: "America/Toronto")!
    private let idPrefix = "stc.sched."

    private init() {}

    /// Stores the per-tab route config + schedule settings from the web page
    /// and (re)arms the notification triggers. Mirrors Android's
    /// applyScheduleSettings() — safe to call with no active ride.
    func apply(config: RideState) {
        let tabKey = config.tab == "pm" ? "pm" : "am"
        LocationTracker.shared.schedLog("apply tab=\(tabKey) enabled=\(config.schedEnabled) on1=\(config.schedOn1) on2=\(config.schedOn2) weekdaysOnly=\(config.schedWeekdaysOnly)")
        if let data = try? JSONSerialization.data(withJSONObject: config.toJSON()) {
            UserDefaults.standard.set(data, forKey: "stcecilia_sched_config_" + tabKey)
        }
        let d = UserDefaults.standard
        d.set(config.schedEnabled, forKey: "stcecilia_sched_enabled")
        d.set(config.schedOn1, forKey: "stcecilia_sched_on1")
        d.set(config.schedOn2, forKey: "stcecilia_sched_on2")
        d.set(config.schedWeekdaysOnly, forKey: "stcecilia_sched_weekdays")
        schedule()
    }

    /// Full config JSON last saved for a tab ("am"/"pm").
    func configJSON(forTab tab: String) -> String? {
        let key = "stcecilia_sched_config_" + (tab == "pm" ? "pm" : "am")
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Arming is serialized: only one remove→add pass runs at a time, and the
    // adds are submitted inside the pending-fetch completion, immediately
    // after the removal call — so a removal can never land after the adds it
    // was meant to precede (the v31 logs proved that race: a re-arm while
    // notifications were armed ended with pending count=0). Overlapping
    // schedule() calls coalesce into one follow-up pass.
    private var arming = false
    private var rearmQueued = false
    private var armCompletions: [() -> Void] = []

    /// (Re)programs the start-time notifications from stored settings.
    /// The optional completion fires once this pass has submitted its adds
    /// (used by the background-refresh handler).
    func schedule(completion: (() -> Void)? = nil) {
        LocationTracker.shared.schedLog("schedule() begin")
        if let completion = completion { armCompletions.append(completion) }
        if arming {
            rearmQueued = true
            LocationTracker.shared.schedLog("schedule: arm already in flight - follow-up pass queued")
            return
        }
        arming = true
        performSchedule()
    }

    private func performSchedule() {
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: "stcecilia_sched_enabled")
        let on1 = d.integer(forKey: "stcecilia_sched_on1")
        let on2 = d.integer(forKey: "stcecilia_sched_on2")
        let weekdaysOnly = d.bool(forKey: "stcecilia_sched_weekdays")
        LocationTracker.shared.schedLog("stored enabled=\(enabled) on1=\(on1) on2=\(on2) weekdaysOnly=\(weekdaysOnly)")
        // Note: integer(forKey:) returns 0 when unset; fall back to defaults
        // (08:00 AM window, 15:30 PM window — same as Android).
        let morning = on1 > 0 ? on1 : 480
        let afternoon = on2 > 0 ? on2 : 930
        if enabled {
            center.getNotificationSettings { settings in
                LocationTracker.shared.schedLog("notification authorizationStatus=\(settings.authorizationStatus.rawValue) (0=notDetermined 1=denied 2=authorized 3=provisional)")
            }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                LocationTracker.shared.schedLog("requestAuthorization granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            }
        }
        // Serialized remove→add: fetch what's pending, remove ours, and only
        // then submit the new requests — all inside this one completion, in
        // submission order.
        center.getPendingNotificationRequests { [weak self] reqs in
            guard let self = self else { return }
            let ids = reqs.map { $0.identifier }.filter { $0.hasPrefix(self.idPrefix) }
            LocationTracker.shared.schedLog("removeAlarms: found count=\(ids.count) ids=\(ids.sorted().joined(separator: ","))")
            self.center.removePendingNotificationRequests(withIdentifiers: ids)
            if enabled {
                self.addStartAlarm(minutes: morning, tab: "am", weekdaysOnly: weekdaysOnly, morning: true)
                self.addStartAlarm(minutes: afternoon, tab: "pm", weekdaysOnly: weekdaysOnly, morning: false)
            } else {
                LocationTracker.shared.schedLog("schedule SKIPPED adds: enabled=false (pending cleared)")
            }
            self.verifyPending(after: "schedule")
            self.finishArm()
        }
    }

    private func finishArm() {
        arming = false
        let completions = armCompletions
        armCompletions.removeAll()
        completions.forEach { $0() }
        if rearmQueued {
            rearmQueued = false
            schedule()
        }
    }

    /// Read-only check, ~1s later: what notifications are actually pending.
    private func verifyPending(after label: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.center.getPendingNotificationRequests { reqs in
                let ids = reqs.map { $0.identifier }.filter { $0.hasPrefix(self.idPrefix) }.sorted()
                LocationTracker.shared.schedLog("pending after \(label): count=\(ids.count) ids=\(ids.joined(separator: ","))")
            }
        }
    }

    private func addStartAlarm(minutes: Int, tab: String,
                              weekdaysOnly: Bool, morning: Bool) {
        LocationTracker.shared.schedLog("addStartAlarm tab=\(tab) minutes=\(minutes) weekdaysOnly=\(weekdaysOnly)")
        let content = UNMutableNotificationContent()
        content.title = "St Cecilia"
        content.body = morning
            ? "Time for the morning ride — tap to start tracking."
            : "Time for the afternoon ride — tap to start tracking."
        content.sound = .default
        content.userInfo = ["schedTab": tab]

        var components = DateComponents()
        components.timeZone = toronto
        components.hour = (minutes / 60) % 24
        components.minute = minutes % 60

        if weekdaysOnly {
            // UNCalendarNotificationTrigger can't express Mon–Fri in one
            // trigger, so schedule five weekly ones.
            for weekday in 2...6 { // 1=Sun … 7=Sat
                var c = components
                c.weekday = weekday
                let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: true)
                let req = UNNotificationRequest(
                    identifier: "\(idPrefix)\(tab).\(weekday)",
                    content: content, trigger: trigger)
                center.add(req) { error in
                    if let error = error {
                        LocationTracker.shared.schedLog("add FAILED id=\(req.identifier) error=\(error.localizedDescription)")
                    } else {
                        LocationTracker.shared.schedLog("add OK id=\(req.identifier)")
                    }
                }
            }
        } else {
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let req = UNNotificationRequest(
                identifier: "\(idPrefix)\(tab).daily",
                content: content, trigger: trigger)
            center.add(req) { error in
                if let error = error {
                    LocationTracker.shared.schedLog("add FAILED id=\(req.identifier) error=\(error.localizedDescription)")
                } else {
                    LocationTracker.shared.schedLog("add OK id=\(req.identifier)")
                }
            }
        }
    }
}
