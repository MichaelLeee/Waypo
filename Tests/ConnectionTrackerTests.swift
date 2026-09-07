import Testing
@testable import Waypo

@Suite
struct ConnectionTrackerTests {
    private func connection(_ id: String, createdAt: Int64 = 0,
                            upload: UInt64 = 0, download: UInt64 = 0) -> EngineConnection {
        EngineConnection(id: id, network: "tcp", destination: "\(id).example.com:443",
                         domain: nil, outbound: "out", rule: nil,
                         upload: upload, download: download, createdAt: createdAt)
    }

    @Test
    func upsertInsertsAndReplaces() {
        var tracker = ConnectionTracker()
        tracker.upsert(connection("a", createdAt: 1))
        tracker.upsert(connection("b", createdAt: 2))
        #expect(tracker.connections.map(\.id) == ["b", "a"])

        tracker.upsert(connection("a", createdAt: 1, upload: 10, download: 20))
        #expect(tracker.connections.count == 2)
        #expect(tracker.connections.first { $0.id == "a" }?.upload == 10)
    }

    @Test
    func connectionsSortByNewestFirst() {
        var tracker = ConnectionTracker()
        tracker.upsert(connection("old", createdAt: 100))
        tracker.upsert(connection("new", createdAt: 300))
        tracker.upsert(connection("mid", createdAt: 200))
        #expect(tracker.connections.map(\.id) == ["new", "mid", "old"])
    }

    @Test
    func trafficDeltaAddsToKnownConnection() {
        var tracker = ConnectionTracker()
        tracker.upsert(connection("a", upload: 100, download: 200))
        tracker.addTraffic(id: "a", upload: 5, download: 7)
        let updated = tracker.connections.first { $0.id == "a" }
        #expect(updated?.upload == 105)
        #expect(updated?.download == 207)
    }

    @Test
    func trafficDeltaForUnknownConnectionIsIgnored() {
        var tracker = ConnectionTracker()
        tracker.addTraffic(id: "ghost", upload: 5, download: 5)
        #expect(tracker.isEmpty)
    }

    @Test
    func closeRemovesAndResetClears() {
        var tracker = ConnectionTracker()
        tracker.upsert(connection("a"))
        tracker.upsert(connection("b"))
        tracker.close(id: "a")
        #expect(tracker.connections.map(\.id) == ["b"])

        tracker.reset()
        #expect(tracker.isEmpty)
    }
}
