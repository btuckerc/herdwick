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

struct WatchedRunWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WatchedRunAttributes.self) { context in
            VStack(alignment: .leading) {
                Text(context.attributes.title).font(.headline).lineLimit(1)
                Text(context.attributes.host).font(.caption)
                Text(context.isStale ? "Update overdue — open Herdwick" : label(context.state.status))
            }
            .padding()
            .widgetURL(URL(string: "herdwick://inbox"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "terminal") }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Update overdue" : label(context.state.status))
                }
            } compactLeading: { Image(systemName: "terminal") }
              compactTrailing: { Image(systemName: symbol(context.state.status)) }
              minimal: { Image(systemName: symbol(context.state.status)) }
            .widgetURL(URL(string: "herdwick://inbox"))
        }
    }
    private func label(_ status: String) -> String {
        switch status { case "blocked": "Needs you"; case "done": "Finished"; default: "Working" }
    }
    private func symbol(_ status: String) -> String {
        switch status { case "blocked": "exclamationmark.bubble"; case "done": "checkmark"; default: "ellipsis" }
    }
}
