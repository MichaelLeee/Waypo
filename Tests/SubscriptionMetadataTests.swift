import Foundation
import Testing

@Suite
struct SubscriptionMetadataTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func readsEveryKnownField() throws {
        let info = SubscriptionUserInfo.parse(
            "upload=1000; download=2500000; total=10000000; expire=1900000000", updatedAt: now)
        #expect(info?.uploadBytes == 1_000)
        #expect(info?.downloadBytes == 2_500_000)
        #expect(info?.totalBytes == 10_000_000)
        #expect(info?.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(info?.updatedAt == now)
    }

    @Test
    func toleratesSpacingQuotingAndCase() throws {
        let info = SubscriptionUserInfo.parse(
            "UPLOAD = 10 ;download=20; TOTAL = \"300\" ;expire=\"1700000000\"", updatedAt: now)
        #expect(info?.uploadBytes == 10)
        #expect(info?.downloadBytes == 20)
        #expect(info?.totalBytes == 300)
        #expect(info?.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func ignoresKeysItDoesNotKnow() throws {
        let info = SubscriptionUserInfo.parse(
            "reset_day=1; plan=pro; total=500; note=hello", updatedAt: now)
        #expect(info?.totalBytes == 500)
        #expect(info?.uploadBytes == nil)
        #expect(info?.downloadBytes == nil)
    }

    @Test
    func returnsNothingWhenNoKnownFieldIsPresent() throws {
        #expect(SubscriptionUserInfo.parse(nil) == nil)
        #expect(SubscriptionUserInfo.parse("") == nil)
        #expect(SubscriptionUserInfo.parse("reset_day=1; plan=pro") == nil)
    }

    @Test
    func aPartialLineKeepsWhatItHas() throws {
        // One unusable value must not discard the fields beside it.
        let info = SubscriptionUserInfo.parse("upload=abc; download=42", updatedAt: now)
        #expect(info?.uploadBytes == nil)
        #expect(info?.downloadBytes == 42)
        #expect(info?.totalBytes == nil)
    }

    @Test
    func rejectsNegativeAndNonNumericCounts() throws {
        #expect(SubscriptionUserInfo.parse("upload=-5", updatedAt: now) == nil)
        #expect(SubscriptionUserInfo.parse("upload=1e300", updatedAt: now) == nil)
    }

    @Test
    func keepsCountsBeyondTheInt32Range() throws {
        // A generous plan exceeds 2^31 bytes, which is where a narrowing
        // conversion would wrap.
        let info = SubscriptionUserInfo.parse("total=5368709120; download=4294967296", updatedAt: now)
        #expect(info?.totalBytes == 5_368_709_120)
        #expect(info?.downloadBytes == 4_294_967_296)
    }

    @Test
    func acceptsAMillisecondExpiry() throws {
        // No date in seconds is this far away, so the magnitude is the tell.
        let info = SubscriptionUserInfo.parse("expire=1900000000000", updatedAt: now)
        #expect(info?.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test
    func usageIsTheSumOfBothDirections() throws {
        let info = SubscriptionUserInfo.parse("upload=100; download=200", updatedAt: now)
        #expect(info?.usedBytes == 300)
        let uploadOnly = SubscriptionUserInfo.parse("upload=100", updatedAt: now)
        #expect(uploadOnly?.usedBytes == 100)
        // Neither direction alone is enough to be a total.
        #expect(SubscriptionUserInfo.parse("total=100", updatedAt: now)?.usedBytes == nil)
    }

    @Test
    func remainingFloorsAtZeroAndFractionStaysWithinBounds() throws {
        let over = SubscriptionUserInfo.parse("upload=100; download=100; total=50", updatedAt: now)
        #expect(over?.remainingBytes == 0)
        #expect(over?.usedFraction == 1)

        let half = SubscriptionUserInfo.parse("download=50; total=100", updatedAt: now)
        #expect(half?.remainingBytes == 50)
        #expect(half?.usedFraction == 0.5)
    }

    @Test
    func derivedValuesAreAbsentWithoutTheirInputs() throws {
        let onlyTotal = SubscriptionUserInfo.parse("total=100", updatedAt: now)
        #expect(onlyTotal?.usedBytes == nil)
        #expect(onlyTotal?.remainingBytes == nil)
        #expect(onlyTotal?.usedFraction == nil)

        // A plan with no stated total has no fraction, and zero is not a
        // denominator.
        let noTotal = SubscriptionUserInfo.parse("download=50; total=0", updatedAt: now)
        #expect(noTotal?.usedFraction == nil)
    }

    @Test
    func expiryIsComparedAgainstNow() throws {
        let past = SubscriptionUserInfo.parse("expire=1700000000", updatedAt: now)
        #expect(past?.isExpired == true)
        let future = SubscriptionUserInfo.parse("expire=1900000000", updatedAt: now)
        #expect(future?.isExpired == false)
        // No expiry stated is not an expired account.
        #expect(SubscriptionUserInfo.parse("total=1", updatedAt: now)?.isExpired == false)
    }

    @Test
    func roundTripsThroughJSON() throws {
        let info = SubscriptionUserInfo.parse(
            "upload=1000; download=2500000; total=10000000; expire=1900000000", updatedAt: now)
        let decoded = try JSONDecoder().decode(
            SubscriptionUserInfo.self, from: try JSONEncoder().encode(info))
        #expect(decoded == info)
    }
}
