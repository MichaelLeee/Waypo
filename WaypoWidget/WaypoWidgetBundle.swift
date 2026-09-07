import SwiftUI
import WidgetKit

@main
struct WaypoWidgetBundle: WidgetBundle {
    var body: some WidgetBundle {
        WaypoWidget()
        #if os(iOS)
        WaypoControl()
        #endif
    }
}
