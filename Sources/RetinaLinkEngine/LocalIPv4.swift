import Darwin
import Foundation
import RetinaLinkCore
import SystemConfiguration

struct LocalIPv4: Hashable {
    let interface: String
    let host: String

    static func snapshot() -> Set<Self> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var addresses = Set<Self>()
        var current: UnsafeMutablePointer<ifaddrs>? = head
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        while let item = current?.pointee {
            current = item.ifa_next
            guard let address = item.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK) == UInt32(IFF_UP | IFF_RUNNING),
                  getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addresses.insert(Self(interface: String(cString: item.ifa_name),
                                  host: String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)))
        }
        return addresses
    }

    static func linkSpeedMbps(forInterface name: String) -> Int? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var current: UnsafeMutablePointer<ifaddrs>? = head
        while let item = current?.pointee {
            current = item.ifa_next
            guard item.ifa_addr?.pointee.sa_family == sa_family_t(AF_LINK),
                  String(cString: item.ifa_name) == name,
                  let data = item.ifa_data else { continue }
            let baud = data.assumingMemoryBound(to: if_data.self).pointee.ifi_baudrate
            let mbps = Int(baud / 1_000_000)
            return mbps > 0 ? mbps : nil
        }
        return nil
    }

    static func hardwareKinds() -> [String: LinkKind] {
        let interfaces = SCNetworkInterfaceCopyAll() as NSArray as? [SCNetworkInterface] ?? []
        var hardware = [String: LinkKind]()
        for interface in interfaces {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            switch SCNetworkInterfaceGetInterfaceType(interface) {
            case kSCNetworkInterfaceTypeIEEE80211: hardware[bsd] = .wifi
            case kSCNetworkInterfaceTypeEthernet: hardware[bsd] = .wiredEthernet
            default: break
            }
        }
        return hardware
    }

    func kind(hardware: [String: LinkKind]) -> LinkKind? {
        EndpointRanker.interfaceKind(name: interface, ipv4: host, hardwareKind: hardware[interface])
    }

    // Some USB-C link-local addresses appear after the default network path settles.
    @MainActor static func poll(_ changed: @escaping @MainActor (Set<Self>) -> Void) -> Task<Void, Never> {
        Task {
            var previous = snapshot()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                let current = snapshot()
                guard current != previous else { continue }
                previous = current
                changed(current)
            }
        }
    }
}
