import Darwin
import Foundation
import Network
import RetinaLinkCore

public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let panelPixelWidth: Int
    public let panelPixelHeight: Int
    public let panelIsHiDPI: Bool
    public let candidates: [EndpointCandidate]
    public let bestKnownLink: LinkKind

    init(id: String, advertisement: BonjourAdvertisement) {
        self.id = id
        name = advertisement.name
        panelPixelWidth = advertisement.panelPixelWidth
        panelPixelHeight = advertisement.panelPixelHeight
        panelIsHiDPI = advertisement.panelIsHiDPI
        candidates = advertisement.candidates
        bestKnownLink = EndpointRanker.best(candidates)?.kind ?? .wifi
    }
}

@MainActor
public final class LinkDiscovery {
    public static let serviceType = "_retinalink._tcp"
    public var onPeers: (([DiscoveredPeer]) -> Void)?
    public var onPathChange: (() -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var peers: [DiscoveredPeer] = []
    private var browser: NWBrowser?
    private var monitor: NWPathMonitor?
    private var addressPoll: Task<Void, Never>?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                MainActor.assumeIsolated { self?.onError?(error.localizedDescription) }
            }
        }
        browser.start(queue: .main)
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.onPathChange?() }
        }
        monitor.start(queue: .main)
        addressPoll = LocalIPv4.poll { [weak self] _ in self?.onPathChange?() }
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        monitor?.cancel()
        monitor = nil
        addressPoll?.cancel()
        addressPoll = nil
        peers = []
    }

    public static func probe(_ candidates: [EndpointCandidate]) async -> [EndpointCandidate] {
        await withTaskGroup(of: EndpointCandidate?.self) { group in
            for candidate in candidates {
                group.addTask { await probeOne(candidate) }
            }
            var results = [EndpointCandidate]()
            for await candidate in group {
                if let candidate { results.append(candidate) }
            }
            return EndpointRanker.ranked(results)
        }
    }

    private static func probeOne(_ candidate: EndpointCandidate) async -> EndpointCandidate? {
        guard !Task.isCancelled else { return nil }
        let session = TransportSession(candidate: candidate)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyCancelled = Task.isCancelled
                MediaQueue.sync {
                    guard !alreadyCancelled, !session.isClosed else { continuation.resume(returning: nil); return }
                    session.onReady = { [weak session] in session?.ping(timestamp: DispatchTime.now().uptimeNanoseconds) }
                    session.onRTT = { [weak session] ms in
                        guard let session else { return }
                        session.onClose = nil
                        continuation.resume(returning: EndpointCandidate(kind: candidate.kind, host: candidate.host,
                                                                        port: candidate.port, rttMs: ms))
                        session.close()
                    }
                    session.onClose = { _ in continuation.resume(returning: nil) }
                    session.start(heartbeats: false)
                }
            }
        } onCancel: {
            session.close()
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let updated = results.compactMap { result -> DiscoveredPeer? in
            guard case .bonjour(let record) = result.metadata,
                  let advertisement = BonjourAdvertisement(txtRecord: record.dictionary) else { return nil }
            return DiscoveredPeer(id: String(describing: result.endpoint), advertisement: advertisement)
        }.sorted { $0.id < $1.id }
        guard updated != peers else { return }
        peers = updated
        onPeers?(updated)
    }

    deinit {
        browser?.cancel()
        monitor?.cancel()
        addressPoll?.cancel()
    }
}

@MainActor
public final class LinkListener {
    public var onSession: ((TransportSession, UInt16?, [EndpointCandidate]) -> Void)?
    public var onCursor: ((CursorPosition, String) -> Void)?
    public var onListening: ((UInt16, [EndpointCandidate]) -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var port: UInt16?

    private let name: String
    private let width: Int
    private let height: Int
    private let panelIsHiDPI: Bool
    private var listener: NWListener?
    private var cursorListener: NWListener?
    private var cursorPort: UInt16?
    private var cursorClients: [NWEndpoint: NWConnection] = [:]
    private var monitor: NWPathMonitor?
    private var addressPoll: Task<Void, Never>?
    private var announced = false
    private var addresses: [EndpointCandidate] = []

    public init(name: String, width: Int, height: Int, panelIsHiDPI: Bool = true) {
        self.name = name
        self.width = width
        self.height = height
        self.panelIsHiDPI = panelIsHiDPI
    }

    public func start(port requestedPort: UInt16 = 58420) throws {
        guard listener == nil else { return }
        do {
            try startTCP(requestedPort)
        } catch where requestedPort != 0 {
            try startTCP(0)
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        monitor.start(queue: .main)
        addressPoll = LocalIPv4.poll { [weak self] snapshot in self?.publish(snapshot) }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        cursorListener?.cancel()
        cursorListener = nil
        cursorClients.values.forEach { $0.cancel() }
        cursorClients.removeAll()
        monitor?.cancel()
        monitor = nil
        addressPoll?.cancel()
        addressPoll = nil
        port = nil
        cursorPort = nil
        announced = false
        addresses = []
    }

    private func startTCP(_ requestedPort: UInt16) throws {
        let listener = try NWListener(using: TransportSession.tcpParameters(),
                                      on: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated { [self] in
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    if let port = self.port { self.startUDP(port: port) }
                case .failed(let error):
                    listener.cancel()
                    self.listener = nil
                    if requestedPort != 0, self.port == nil {
                        do { try self.startTCP(0) }
                        catch { self.onError?(error.localizedDescription) }
                    } else {
                        self.onError?(error.localizedDescription)
                    }
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { [self] in
                guard let self, let onSession = self.onSession else { connection.cancel(); return }
                onSession(TransportSession(connection: connection), self.cursorPort, self.addresses)
            }
        }
        listener.start(queue: .main)
    }

    private func startUDP(port: UInt16) {
        do {
            let cursorListener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port) ?? .any)
            self.cursorListener = cursorListener
            cursorListener.stateUpdateHandler = { [weak self, weak cursorListener] state in
                MainActor.assumeIsolated { [self] in
                    guard let self, let cursorListener, self.cursorListener === cursorListener else { return }
                    if case .ready = state {
                        self.cursorPort = cursorListener.port?.rawValue
                        self.announced = true
                        self.publish()
                    }
                    if case .failed = state {
                        cursorListener.cancel()
                        self.cursorListener = nil
                        self.cursorPort = nil
                        self.announced = true
                        self.publish()
                    }
                }
            }
            cursorListener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.startCursorClient(connection) }
            }
            cursorListener.start(queue: .main)
        } catch {
            announced = true
            publish()
        }
    }

    private func startCursorClient(_ connection: NWConnection) {
        guard cursorClients.count < 16, cursorClients[connection.endpoint] == nil else {
            connection.cancel()
            return
        }
        cursorClients[connection.endpoint] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated { [self] in
                guard let self, let connection else { return }
                switch state {
                case .failed, .cancelled: self.removeCursorClient(connection)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receiveCursor(connection)
    }

    func clearCursorClients() {
        let clients = Array(cursorClients.values)
        clients.forEach { removeCursorClient($0) }
    }

    private func removeCursorClient(_ connection: NWConnection) {
        guard cursorClients.removeValue(forKey: connection.endpoint) != nil else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receiveCursor(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            MainActor.assumeIsolated { [self] in
                guard let self, let connection, self.cursorClients[connection.endpoint] === connection else { return }
                guard error == nil else { self.removeCursorClient(connection); return }
                if let data, let address = TransportSession.address(connection.endpoint),
                   let position = try? CursorPosition(decoding: data) {
                    self.onCursor?(position, address)
                }
                self.receiveCursor(connection)
            }
        }
    }

    private func publish(_ snapshot: Set<LocalIPv4> = LocalIPv4.snapshot()) {
        guard announced, let listener, let port else { return }
        let updated = Self.localAddresses(port: port, snapshot: snapshot)
        guard listener.service == nil || updated != addresses else { return }
        addresses = updated
        let advertisement = BonjourAdvertisement(name: name, port: port, panelPixelWidth: width,
                                                 panelPixelHeight: height, candidates: addresses, panelIsHiDPI: panelIsHiDPI)
        let service = NWListener.Service(name: name, type: LinkDiscovery.serviceType,
                                         txtRecord: NWTXTRecord(advertisement.txtRecord))
        if listener.service != service { listener.service = service }
        onListening?(port, addresses)
    }

    public static func localAddresses(port: UInt16) -> [EndpointCandidate] {
        localAddresses(port: port, snapshot: LocalIPv4.snapshot())
    }

    private static func localAddresses(port: UInt16, snapshot: Set<LocalIPv4>) -> [EndpointCandidate] {
        let hardware = LocalIPv4.hardwareKinds()
        let addresses = Set(snapshot.compactMap { entry -> EndpointCandidate? in
            guard let kind = entry.kind(hardware: hardware) else { return nil }
            return EndpointCandidate(kind: kind, host: entry.host, port: port)
        })
        return EndpointRanker.ranked(Array(addresses))
    }

    deinit {
        listener?.cancel()
        cursorListener?.cancel()
        monitor?.cancel()
        addressPoll?.cancel()
    }
}
