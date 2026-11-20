import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct NeedsYouControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.btuckerc.herdwick.needs-you") {
            ControlWidgetButton(action: OpenNeedsYouIntent()) {
                Label("Needs You", systemImage: "exclamationmark.bubble")
            }
        }
        .displayName("Open Needs You")
        .description("Open Herdwick to agents waiting for you.")
    }
}

/// The Live Activity for one watched agent: the app's sheep, the agent and where it runs, the
/// elapsed time large at the trailing edge while it works (counting from the message that
/// started the turn), and under them a status chip in the app's colours (orange only for Needs
/// you) beside the agent's latest step, given two lines (round 12: three plain lines, no glyph
/// or time; round 14: a bare timer with no meaning; round 16: four stacked lines with the status
/// badged on the sheep read as a text slab, the time no larger than the words).
struct WatchedRunWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WatchedRunAttributes.self) { context in
            lockScreen(context)
                .widgetURL(context.attributes.link)
        } dynamicIsland: { context in
            let status = context.state.status
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HerdMark(size: 34, mood: mood(context)).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        // Two lines, as on the Lock Screen (round 18: one line cut the run's name here).
                        Text(context.attributes.title).font(.headline).lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(place(context.attributes)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(context).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    stateLine(context).padding(.top, 4)
                }
            } compactLeading: {
                HerdMark(size: 22, mood: mood(context))
            } compactTrailing: {
                // Stale, the compact side stops counting as the card does (round 18: a running
                // timer here looked live while the expanded card said Update overdue).
                if context.isStale {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                        .accessibilityLabel("Update overdue")
                } else if status == "working", let started = context.state.since {
                    Text(started, style: .timer).monospacedDigit().foregroundStyle(color(status))
                        .multilineTextAlignment(.trailing).frame(maxWidth: 44)
                } else {
                    Image(systemName: symbol(status)).foregroundStyle(color(status))
                        .accessibilityLabel(label(status))
                }
            } minimal: {
                Image(systemName: context.isStale ? "clock.badge.exclamationmark" : symbol(status))
                    .foregroundStyle(context.isStale ? .secondary : color(status))
                    .accessibilityLabel(context.isStale ? "Update overdue" : label(status))
            }
            .keylineTint(context.isStale ? .secondary : color(status))
            .widgetURL(context.attributes.link)
        }
    }

    private func lockScreen(_ context: ActivityViewContext<WatchedRunAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                HerdMark(size: 34, mood: mood(context))
                VStack(alignment: .leading, spacing: 1) {
                    // Two lines: the title is what names the run (round 17: the clock cut it to "Token-bucket rate li…").
                    Text(context.attributes.title).font(.headline).lineLimit(2)
                    Text(place(context.attributes)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                clock(context)
            }
            stateLine(context)
        }
        .padding(16)
    }

    /// The status as a chip, then what the agent is doing (or asking), on up to two lines.
    private func stateLine(_ context: ActivityViewContext<WatchedRunAttributes>) -> some View {
        let status = context.state.status
        let tint: Color = context.isStale ? .secondary : color(status)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(context.isStale ? "Update overdue" : label(status), systemImage: context.isStale ? "clock.badge.exclamationmark" : symbol(status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.18), in: .capsule)
                .fixedSize()
            if let detail = context.isStale ? "Open Herdwick to refresh" : context.state.detail {
                // The step at the title's own strength, a step under it in size: what the agent
                // is doing is what a glance at the Lock Screen is for (round 87: sa#14, in
                // footnote it was the faintest line on the card, under the name and the clock).
                Text(detail).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Elapsed time while working, said as such (round 17: a bare "1:48"); nothing once it has
    /// stopped (the card then says why), nor when an update came without its run's start (a
    /// relay push carries the status alone): no clock beats an older run's (round 49: sb#1).
    @ViewBuilder private func clock(_ context: ActivityViewContext<WatchedRunAttributes>) -> some View {
        if context.state.status == "working", !context.isStale, let started = context.state.since {
            VStack(alignment: .trailing, spacing: 0) {
                // A timer Text takes all the width it's offered; held to its digits' width.
                Text(started, style: .timer).multilineTextAlignment(.trailing)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color(context.state.status))
                    .frame(maxWidth: 76, alignment: .trailing)
                Text("elapsed").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The sheep wears the run's state as it does in the app: the blinking prompt while it works,
    /// the orange badge when it needs you, the check when done, asleep once closed or overdue
    /// (round 91: opus#2, sa#9, the same still sheep on every card said nothing).
    private func mood(_ context: ActivityViewContext<WatchedRunAttributes>) -> HerdMark.Mood {
        if context.isStale { return .quiet }
        switch context.state.status {
        case "blocked": return .waiting
        case "done": return .done
        case "closed": return .quiet
        default: return .working
        }
    }

    private func place(_ attributes: WatchedRunAttributes) -> String {
        [attributes.place, attributes.host].compactMap { $0 }.joined(separator: " · ")
    }
    private func label(_ status: String) -> String {
        switch status { case "blocked": "Needs you"; case "done": "Done"; case "closed": "Closed"; default: "Working" }
    }
    private func symbol(_ status: String) -> String {
        switch status {
        case "blocked": "exclamationmark.bubble.fill"
        case "done": "checkmark.circle.fill"
        case "closed": "xmark.circle"
        default: "circle.dotted.circle"
        }
    }
    /// The app's colours; orange only ever means "needs you", and an agent gone is grey.
    private func color(_ status: String) -> Color {
        switch status { case "blocked": .orange; case "done": .green; case "closed": .secondary; default: .blue }
    }
}
