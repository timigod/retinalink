public enum LinkKind: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case wifi
    case wiredEthernet
    case thunderbolt

    public var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .wiredEthernet: "Wired LAN"
        case .thunderbolt: "Direct Cable"
        }
    }

    fileprivate var tag: String {
        switch self {
        case .wifi: "wifi"
        case .wiredEthernet: "eth"
        case .thunderbolt: "tb"
        }
    }

    private var priority: Int {
        switch self {
        case .wifi: 1
        case .wiredEthernet: 2
        case .thunderbolt: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.priority < rhs.priority }
}

public struct EndpointCandidate: Codable, Hashable, Sendable {
    public let kind: LinkKind
    public let host: String
    public let port: UInt16
    public let rttMs: Double?

    public init(kind: LinkKind, host: String, port: UInt16, rttMs: Double? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.rttMs = rttMs
    }
}

public struct BonjourAdvertisement: Hashable, Sendable {
    public let name: String
    public let port: UInt16
    public let panelPixelWidth: Int
    public let panelPixelHeight: Int
    public let candidates: [EndpointCandidate]
    public let panelIsHiDPI: Bool

    public init(name: String, port: UInt16, panelPixelWidth: Int, panelPixelHeight: Int, candidates: [EndpointCandidate], panelIsHiDPI: Bool = true) {
        self.name = name
        self.port = port
        self.panelPixelWidth = panelPixelWidth
        self.panelPixelHeight = panelPixelHeight
        self.candidates = candidates
        self.panelIsHiDPI = panelIsHiDPI
    }

    public var txtRecord: [String: String] {
        [
            "addrs": EndpointRanker.encodeAddresses(candidates),
            "port": String(port),
            "w": String(panelPixelWidth),
            "h": String(panelPixelHeight),
            "name": name,
            "hidpi": panelIsHiDPI ? "1" : "0",
        ]
    }

    public init?(txtRecord: [String: String]) {
        guard let name = txtRecord["name"], !name.isEmpty,
              let port = txtRecord["port"].flatMap(UInt16.init), port > 0,
              let width = txtRecord["w"].flatMap(UInt16.init), width > 0,
              let height = txtRecord["h"].flatMap(UInt16.init), height > 0,
              let addresses = txtRecord["addrs"] else { return nil }
        self.init(
            name: name, port: port, panelPixelWidth: Int(width), panelPixelHeight: Int(height),
            candidates: EndpointRanker.decodeAddresses(addresses, port: port), panelIsHiDPI: txtRecord["hidpi"] != "0"
        )
    }
}

public enum EndpointRanker {
    public static func interfaceKind(name: String, ipv4: String, hardwareKind: LinkKind?) -> LinkKind? {
        guard isIPv4(ipv4) else { return nil }
        if name.hasPrefix("bridge") || (name.hasPrefix("en") && ipv4.hasPrefix("169.254.")) {
            return .thunderbolt
        }
        return hardwareKind
    }

    public static func effectiveLinkKind(localEgress: LinkKind?, receiverIngress: LinkKind) -> LinkKind {
        min(localEgress ?? .wifi, receiverIngress)
    }

    public static func ranked(_ candidates: [EndpointCandidate]) -> [EndpointCandidate] {
        func latency(_ candidate: EndpointCandidate) -> Double {
            guard let rtt = candidate.rttMs, rtt.isFinite, rtt >= 0 else { return .infinity }
            return rtt
        }
        return candidates.sorted {
            if $0.kind != $1.kind { return $0.kind > $1.kind }
            if latency($0) != latency($1) { return latency($0) < latency($1) }
            if $0.host != $1.host { return $0.host < $1.host }
            return $0.port < $1.port
        }
    }

    public static func best(_ candidates: [EndpointCandidate]) -> EndpointCandidate? {
        ranked(candidates).first
    }

    public static func encodeAddresses(_ candidates: [EndpointCandidate]) -> String {
        var seen = Set<String>()
        return ranked(candidates).compactMap { candidate in
            guard isIPv4(candidate.host) else { return nil }
            let entry = "\(candidate.kind.tag):\(candidate.host)"
            return seen.insert(entry).inserted ? entry : nil
        }.joined(separator: ",")
    }

    public static func decodeAddresses(_ record: String, port: UInt16) -> [EndpointCandidate] {
        var seen = Set<EndpointCandidate>()
        return ranked(record.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let kind = LinkKind.allCases.first(where: { $0.tag == parts[0] }),
                  isIPv4(String(parts[1])) else { return nil }
            let candidate = EndpointCandidate(kind: kind, host: String(parts[1]), port: port)
            return seen.insert(candidate).inserted ? candidate : nil
        })
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt8($0) != nil
        }
    }
}
