import SwiftUI
import WidgetKit

@main
struct WaypoWidgetBundle: WidgetBundle {
    var body: some Widget {
        WaypoWidget()
        #if os(iOS)
        WaypoControl()
        #endif
    }
}
