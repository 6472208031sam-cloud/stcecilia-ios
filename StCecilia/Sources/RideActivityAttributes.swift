import Foundation
import ActivityKit

/// Live Activity attributes + content state for a ride (v45). This file
/// is compiled into BOTH the app target (which starts / updates / ends
/// activities via LiveActivityManager) and the widget extension (which
/// renders them) — the two sides must agree on these types exactly.
///
/// The card is one more renderer of the tracker's ride snapshot: the
/// per-stop status array is copied from the ride's stops, nothing is
/// computed here that the tracker does not already own.
@available(iOS 18.0, *)
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Per-stop status: 0 = pending, 1 = reached, 2 = skipped.
        var statuses: [Int]
        /// Index of the next unreached stop, -1 when none remains.
        var nextIndex: Int
        /// How many stops are reached.
        var reachedCount: Int
        /// True once the ride has completed.
        var completed: Bool
    }
    /// "am" or "pm".
    var route: String
    /// Total number of stops on the route.
    var total: Int
    /// Ordered stop ids exactly as the in-app chips show them
    /// ("1".."13" / "S","0","01","02","A".."L").
    var stopIds: [String]
    /// The ride's id — LiveActivityManager keys activities by this.
    var rideId: String
}
