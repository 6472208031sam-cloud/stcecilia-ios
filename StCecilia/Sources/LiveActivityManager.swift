import Foundation
import ActivityKit

/// Live Activity lifecycle for rides (v45). The lock-screen card is one
/// more renderer of the tracker's ride snapshot: an activity starts when
/// a ride is created, receives a new content state whenever persist()
/// reports the stop-status array changed, and ends when the ride ends.
/// Keyed by rideId throughout — a repeat start for the same ride updates
/// its activity instead of creating a second one (the v44 activation+tap
/// resync pattern), and a start for a new ride first ends any activity
/// belonging to another ride.
///
/// Every facade entry point is safe on any iOS version: below iOS 18
/// (the extension's floor), or with Live Activities turned off for the
/// app, the call logs a [LIVE] line (or stays silent on old systems) and
/// does nothing. Activity failures never affect tracking.
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private init() {}

    // MARK: Facade ( callable from the iOS 15-target tracker )

    func start(ride: RideState) {
        guard #available(iOS 18.0, *) else { return }
        LiveActivityEngine.shared.start(ride: ride)
    }

    func sync(ride: RideState) {
        guard #available(iOS 18.0, *) else { return }
        LiveActivityEngine.shared.sync(ride: ride)
    }

    func end(rideId: String) {
        guard #available(iOS 18.0, *) else { return }
        LiveActivityEngine.shared.end(rideId: rideId, completed: nil)
    }

    func endCompleted(ride: RideState) {
        guard #available(iOS 18.0, *) else { return }
        LiveActivityEngine.shared.end(rideId: ride.rideId, completed: ride)
    }

    func sweep(currentRideId: String?) {
        guard #available(iOS 18.0, *) else { return }
        LiveActivityEngine.shared.sweep(currentRideId: currentRideId)
    }

    // MARK: Snapshot helpers (plain values, no ActivityKit types)

    /// 0 = pending, 1 = reached, 2 = skipped — copied from the stops.
    static func statuses(for ride: RideState) -> [Int] {
        return ride.stops.map { $0.skipped ? 2 : ($0.reached ? 1 : 0) }
    }

    static func snapshot(for ride: RideState) -> (statuses: [Int], next: Int, reached: Int) {
        let st = statuses(for: ride)
        let reached = ride.stops.filter { $0.reached && !$0.skipped }.count
        let next = st.firstIndex(of: 0) ?? -1
        return (st, next, reached)
    }

    /// Chip id exactly as the in-app grid shows it: St Cecilia's chips
    /// are positional — AM shows 1...9, PM shows A...I (its stop labels
    /// are letter-tagged on both routes, so position is the reliable
    /// source, same as the page's own chips).
    static func chipId(for stop: RideStop, index: Int, route: String) -> String {
        if route == "pm", index >= 0, index < 26 {
            return String(UnicodeScalar(65 + index)!)
        }
        return String(index + 1)
    }
}

@available(iOS 18.0, *)
private final class LiveActivityEngine {
    static let shared = LiveActivityEngine()
    private init() {}

    /// Last content state sent per rideId — sync() compares against it
    /// so persist() stays cheap and updates go out only on real change.
    private var lastSent: [String: RideActivityAttributes.ContentState] = [:]

    private func log(_ msg: String) { LocationTracker.shared.liveLog(msg) }

    /// v46: the card's freshness deadline — 10 minutes past every
    /// send (Domi's pick). A live ride renews it at every stop event;
    /// if updates stop (force-quit, app death), the system dims the
    /// card instead of letting it pose as live.
    private func freshStaleDate() -> Date { Date().addingTimeInterval(600) }

    private func makeState(_ ride: RideState) -> RideActivityAttributes.ContentState {
        let snap = LiveActivityManager.snapshot(for: ride)
        return RideActivityAttributes.ContentState(
            statuses: snap.statuses, nextIndex: snap.next,
            reachedCount: snap.reached, completed: ride.completed)
    }

    private func activity(for rideId: String) -> Activity<RideActivityAttributes>? {
        return Activity<RideActivityAttributes>.activities.first { $0.attributes.rideId == rideId }
    }

    func start(ride: RideState) {
        guard !ride.rideId.isEmpty else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log("skip - Live Activities disabled ride=\(String(ride.rideId.prefix(8)))")
            return
        }
        let state = makeState(ride)
        if let existing = activity(for: ride.rideId) {
            lastSent[ride.rideId] = state
            Task { await existing.update(ActivityContent(state: state, staleDate: freshStaleDate())) }
            log("adopt ride=\(String(ride.rideId.prefix(8))) route=\(ride.tab)")
            return
        }
        // A genuinely new ride: end any activity belonging to another
        // ride first (e.g. a lingering completed card).
        for other in Activity<RideActivityAttributes>.activities {
            let oid = other.attributes.rideId
            Task { await other.end(nil, dismissalPolicy: .immediate) }
            lastSent.removeValue(forKey: oid)
            log("end orphan ride=\(String(oid.prefix(8))) (new start)")
        }
        let attrs = RideActivityAttributes(
            route: ride.tab, total: ride.stops.count,
            stopIds: ride.stops.enumerated().map { LiveActivityManager.chipId(for: $0.element, index: $0.offset, route: ride.tab) },
            rideId: ride.rideId)
        do {
            let act = try Activity.request(attributes: attrs, content: ActivityContent(state: state, staleDate: freshStaleDate()), pushType: nil)
            lastSent[ride.rideId] = state
            log("start ride=\(String(act.attributes.rideId.prefix(8))) route=\(attrs.route) total=\(attrs.total)")
        } catch {
            log("start FAILED ride=\(String(ride.rideId.prefix(8))): \(error.localizedDescription)")
        }
    }

    func sync(ride: RideState) {
        guard !ride.rideId.isEmpty, let act = activity(for: ride.rideId) else { return }
        let state = makeState(ride)
        if lastSent[ride.rideId] == state { return }
        lastSent[ride.rideId] = state
        Task { await act.update(ActivityContent(state: state, staleDate: freshStaleDate())) }
        log("update ride=\(String(ride.rideId.prefix(8))) reached=\(state.reachedCount)/\(ride.stops.count)")
    }

    func end(rideId: String, completed: RideState?) {
        guard !rideId.isEmpty else { return }
        guard let act = activity(for: rideId) else {
            lastSent.removeValue(forKey: rideId)
            return
        }
        lastSent.removeValue(forKey: rideId)
        if let ride = completed {
            let state = makeState(ride)
            Task { await act.end(ActivityContent(state: state, staleDate: freshStaleDate()), dismissalPolicy: .after(Date().addingTimeInterval(300))) }
            log("end completed ride=\(String(rideId.prefix(8))) - dismissal +5 min")
        } else {
            Task { await act.end(nil, dismissalPolicy: .immediate) }
            log("end ride=\(String(rideId.prefix(8)))")
        }
    }

    func sweep(currentRideId: String?) {
        for act in Activity<RideActivityAttributes>.activities where act.attributes.rideId != currentRideId {
            let oid = act.attributes.rideId
            Task { await act.end(nil, dismissalPolicy: .immediate) }
            lastSent.removeValue(forKey: oid)
            log("sweep end orphan ride=\(String(oid.prefix(8)))")
        }
    }
}
