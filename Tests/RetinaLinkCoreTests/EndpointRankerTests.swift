import RetinaLinkCore
import XCTest

final class EndpointRankerTests: XCTestCase {
    private let wifi = EndpointCandidate(kind: .wifi, host: "203.0.113.20", port: 58420, rttMs: 1)
    private let ethernet = EndpointCandidate(kind: .wiredEthernet, host: "198.51.100.10", port: 58420, rttMs: 6)
    private let thunderbolt = EndpointCandidate(kind: .thunderbolt, host: "169.254.2.3", port: 58420, rttMs: 20)

    func testLinkTierOutranksRTT() {
        XCTAssertEqual(EndpointRanker.ranked([wifi, thunderbolt, ethernet]), [thunderbolt, ethernet, wifi])
        XCTAssertEqual(EndpointRanker.best([wifi, ethernet]), ethernet)
        XCTAssertEqual(LinkKind.allCases.map(\.displayName), ["Wi-Fi", "Wired LAN", "Direct Cable"])
        XCTAssertNil(EndpointRanker.best([]))
    }

    func testDirectCableClassificationUsesInterfaceAndLinkLocalIPv4() {
        XCTAssertEqual(EndpointRanker.interfaceKind(name: "en6", ipv4: "169.254.72.26", hardwareKind: nil), .thunderbolt)
        XCTAssertEqual(EndpointRanker.interfaceKind(name: "en6", ipv4: "169.254.83.30", hardwareKind: .wiredEthernet), .thunderbolt)
        XCTAssertEqual(EndpointRanker.interfaceKind(name: "bridge0", ipv4: "10.1.0.2", hardwareKind: nil), .thunderbolt)
        XCTAssertEqual(EndpointRanker.interfaceKind(name: "en4", ipv4: "198.51.100.10", hardwareKind: .wiredEthernet), .wiredEthernet)
        XCTAssertEqual(EndpointRanker.interfaceKind(name: "en0", ipv4: "203.0.113.50", hardwareKind: .wifi), .wifi)
        XCTAssertNil(EndpointRanker.interfaceKind(name: "utun6", ipv4: "169.254.1.2", hardwareKind: nil))
        XCTAssertNil(EndpointRanker.interfaceKind(name: "en6", ipv4: "169.254.0.256", hardwareKind: nil))
    }

    func testBadgeUsesSlowerEndWithoutChangingEndpointRanking() {
        XCTAssertEqual(EndpointRanker.effectiveLinkKind(localEgress: .wifi, receiverIngress: .wiredEthernet), .wifi)
        XCTAssertEqual(EndpointRanker.effectiveLinkKind(localEgress: .wiredEthernet, receiverIngress: .wiredEthernet), .wiredEthernet)
        XCTAssertEqual(EndpointRanker.effectiveLinkKind(localEgress: .thunderbolt, receiverIngress: .thunderbolt), .thunderbolt)
        XCTAssertEqual(EndpointRanker.effectiveLinkKind(localEgress: .thunderbolt, receiverIngress: .wifi), .wifi)
        XCTAssertEqual(EndpointRanker.effectiveLinkKind(localEgress: nil, receiverIngress: .thunderbolt), .wifi)
        XCTAssertEqual(EndpointRanker.best([wifi, ethernet, thunderbolt]), thunderbolt)
    }

    func testRTTIsUsedWithinTheSameTier() {
        let faster = EndpointCandidate(kind: .wiredEthernet, host: "198.51.100.200", port: 58420, rttMs: 2.5)
        let notMeasured = EndpointCandidate(kind: .wiredEthernet, host: "198.51.100.100", port: 58420)
        XCTAssertEqual(EndpointRanker.ranked([ethernet, notMeasured, faster]), [faster, ethernet, notMeasured])
    }

    func testStableTieBreakAndInvalidRTT() {
        let first = EndpointCandidate(kind: .wiredEthernet, host: "198.51.100.0", port: 58420, rttMs: 6)
        let otherPort = EndpointCandidate(kind: .wiredEthernet, host: "198.51.100.0", port: 58421, rttMs: 6)
        let invalid = EndpointCandidate(kind: .wiredEthernet, host: "198.51.100.1", port: 58420, rttMs: .nan)
        XCTAssertEqual(EndpointRanker.ranked([otherPort, ethernet, first, invalid]).dropLast(), [first, otherPort, ethernet])
    }

    func testTXTExactEncodingAndDecode() {
        let ad = BonjourAdvertisement(name: "Studio Display Mac", port: 58420, panelPixelWidth: 4480,
                                      panelPixelHeight: 2520, candidates: [wifi, ethernet, thunderbolt, wifi])
        XCTAssertEqual(ad.txtRecord, [
            "addrs": "tb:169.254.2.3,eth:198.51.100.10,wifi:203.0.113.20",
            "port": "58420", "w": "4480", "h": "2520", "name": "Studio Display Mac", "hidpi": "1",
        ])
        let restored = BonjourAdvertisement(txtRecord: ad.txtRecord)
        XCTAssertEqual(restored?.txtRecord, ad.txtRecord)
        XCTAssertEqual(restored?.candidates.map(\.kind), [.thunderbolt, .wiredEthernet, .wifi])
        XCTAssertTrue(restored?.candidates.allSatisfy { $0.port == 58420 && $0.rttMs == nil } == true)
    }

    func testNonRetinaAndLegacyAdvertisements() {
        let ad = BonjourAdvertisement(name: "External panel", port: 58420, panelPixelWidth: 1920,
                                      panelPixelHeight: 1080, candidates: [], panelIsHiDPI: false)
        XCTAssertEqual(ad.txtRecord["hidpi"], "0")
        XCTAssertEqual(BonjourAdvertisement(txtRecord: ad.txtRecord), ad)
        var legacy = ad.txtRecord
        legacy["hidpi"] = nil
        XCTAssertEqual(BonjourAdvertisement(txtRecord: legacy)?.panelIsHiDPI, true)
    }

    func testMalformedTXTEntriesAndAdvertisement() {
        let addresses = EndpointRanker.decodeAddresses(
            "other:10.0.0.1,eth:256.0.0.1,wifi:1.2.3,eth:10.0.0.4,eth:10.0.0.4,tb:1.2.3.+4",
            port: 58421
        )
        XCTAssertEqual(addresses, [EndpointCandidate(kind: .wiredEthernet, host: "10.0.0.4", port: 58421)])
        XCTAssertNil(BonjourAdvertisement(txtRecord: ["port": "58420", "w": "4480", "h": "0", "name": "Studio Display Mac", "addrs": ""]))
    }
}
