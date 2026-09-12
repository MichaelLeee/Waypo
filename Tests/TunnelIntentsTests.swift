import Testing
import Foundation

struct TunnelIntentsTests {
    @Test
    func shortcutsAreRegistered() {
        #expect(WaypoShortcuts.appShortcuts.count == 4)
    }
}
