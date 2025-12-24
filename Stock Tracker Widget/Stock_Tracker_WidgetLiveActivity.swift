//
//  Stock_Tracker_WidgetLiveActivity.swift
//  Stock Tracker Widget
//
//  Created by Ihtisham Mazid on 11/12/2025.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct Stock_Tracker_WidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct Stock_Tracker_WidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Stock_Tracker_WidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension Stock_Tracker_WidgetAttributes {
    fileprivate static var preview: Stock_Tracker_WidgetAttributes {
        Stock_Tracker_WidgetAttributes(name: "World")
    }
}

extension Stock_Tracker_WidgetAttributes.ContentState {
    fileprivate static var smiley: Stock_Tracker_WidgetAttributes.ContentState {
        Stock_Tracker_WidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: Stock_Tracker_WidgetAttributes.ContentState {
         Stock_Tracker_WidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: Stock_Tracker_WidgetAttributes.preview) {
   Stock_Tracker_WidgetLiveActivity()
} contentStates: {
    Stock_Tracker_WidgetAttributes.ContentState.smiley
    Stock_Tracker_WidgetAttributes.ContentState.starEyes
}
