import WidgetKit
import SwiftUI
import ActivityKit

@main
struct RideWidgets: WidgetBundle {
    var body: some Widget {
        RideActivityWidget()
    }
}

// Mock-up palette (live-activity-mockup.html, approved 2026-10-25).
private let chipGreen = Color(red: 0.184, green: 0.749, blue: 0.443)  // #2fbf71
private let iconGreen = Color(red: 0.490, green: 0.310, blue: 0.788)  // #7d4fc9 (St Cecilia purple)
private let amBlue = Color(red: 0.110, green: 0.435, blue: 0.722)     // #1c6fb8
private let pmOrange = Color(red: 0.698, green: 0.373, blue: 0.086)   // #b25f16

struct RideActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideCardView(context: context)
                .activityBackgroundTint(Color(red: 0.11, green: 0.11, blue: 0.125).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.attributes.total) saved · \(context.state.reachedCount) reached")
                        .font(.system(size: 14, weight: .semibold))
                }
            } compactLeading: {
                Text("🚌")
            } compactTrailing: {
                HStack(spacing: 2) {
                    Text("✓").foregroundColor(chipGreen)
                    Text("\(context.state.reachedCount) / \(context.attributes.total)")
                }
                .font(.system(size: 13, weight: .semibold))
            } minimal: {
                Text("🚌")
            }
            .keylineTint(chipGreen)
        }
    }
}

/// The Lock Screen card: header (app + route chip), the GUI's counter
/// phrasing, and the stop-chip grid — nothing else (simplified design,
/// Domi 2026-10-25). Filled green check = reached, outline id = pending,
/// dimmed = skipped, white ring = next stop. No stop names.
struct RideCardView: View {
    let context: ActivityViewContext<RideActivityAttributes>

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(34), spacing: 7), count: 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Text("🚌")
                        .font(.system(size: 15))
                        .frame(width: 26, height: 26)
                        .background(iconGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    Text("St Cecilia")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                Spacer()
                Text(context.attributes.route.uppercased() + " ROUTE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(context.attributes.route == "pm" ? pmOrange : amBlue)
                    .clipShape(Capsule())
            }
            Text(counterText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                ForEach(0..<context.attributes.total, id: \.self) { i in
                    chip(i)
                }
            }
        }
        .padding(16)
    }

    private var counterText: String {
        let base = "\(context.attributes.total) saved · \(context.state.reachedCount) reached"
        return context.state.completed ? base + " — ride complete" : base
    }

    private func chip(_ i: Int) -> some View {
        let status = i < context.state.statuses.count ? context.state.statuses[i] : 0
        let id = i < context.attributes.stopIds.count ? context.attributes.stopIds[i] : "\(i + 1)"
        let isNext = status == 0 && i == context.state.nextIndex
        return ZStack {
            if status == 1 {
                Circle().fill(chipGreen)
                Text("✓").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
            } else if status == 2 {
                Circle().fill(Color.white.opacity(0.14))
                Text(id).font(.system(size: 12, weight: .bold)).foregroundColor(.white.opacity(0.45))
            } else {
                Circle().strokeBorder(chipGreen, lineWidth: 2)
                Text(id).font(.system(size: 12, weight: .bold)).foregroundColor(chipGreen)
            }
        }
        .frame(width: 34, height: 34)
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 2.5)
                .padding(-3.5)
                .opacity(isNext ? 1 : 0)
        )
    }
}
