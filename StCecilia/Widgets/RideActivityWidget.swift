import WidgetKit
import SwiftUI
import ActivityKit

@main
struct RideWidgets: WidgetBundle {
    var body: some Widget {
        RideActivityWidget()
    }
}

struct RideActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            // Lock Screen card (placeholder for the skeleton build — the
            // stop-chip grid layout lands with the lifecycle step).
            Text("Ride in progress")
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("✓ \(context.state.reachedCount) / \(context.attributes.total)")
                }
            } compactLeading: {
                Text("🚌")
            } compactTrailing: {
                Text("✓ \(context.state.reachedCount) / \(context.attributes.total)")
            } minimal: {
                Text("🚌")
            }
        }
    }
}
