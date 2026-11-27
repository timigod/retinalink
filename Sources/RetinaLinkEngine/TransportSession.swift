import Foundation
import Network
import RetinaLinkCore

public final class TransportSession: @unchecked Sendable {
    private let connection: NWConnection
    private var cursorConnection: NWConnection?
    private var reader = FrameBufferReader()
    private var sequence: UInt32 = 0
    private var lastHeartbeatNs = DispatchTime.now().uptimeNanoseconds
    private var heartbeatTimer: (any DispatchSourceTimer)?
    private var closed = false
    private var started = false
    private var ready = false

    @MediaValue private var _onReady: (@Sendable () -> Void)?
    public var onReady: (@Sendable () -> Void)? {
        get { _onReady }
        set { _onReady = newValue }
    }
    @MediaValue private var _onMessage: (@Sendable (WireMessage) -> Void)?
    public var onMessage: (@Sendable (WireMessage) -> Void)? {
        get { _onMessage }
        set { _onMessage = newValue }
    }
    @MediaValue private var _onClose: (@Sendable (String) -> Void)?
    public var onClose: (@Sendable (String) -> Void)? {
        get { _onClose }
        set { _onClose = newValue }
    }
    @MediaValue private var _onRTT: (@Sendable (Double) -> Void)?
    public var onRTT: (@Sendable (Double) -> Void)? {
        get { _onRTT }
        set { _onRTT = newValue }
    }
    @MediaValue private var _roundTripMs: Double?
    public var roundTripMs: Double? {
        get { _roundTripMs }
        set { _roundTripMs = newValue }
    }
    var smoothedRoundTripMs: Double? { MediaQueue.sync { smoothedRTT } }
    private var smoothedRTT: Double?
    var isClosed: Bool { MediaQueue.sync { closed } }
    var localAddress: String? { connection.currentPath?.localEndpoint.flatMap(Self.address) }
    public var remoteAddress: String? {
        Self.address(connection.currentPath?.remoteEndpoint ?? connection.endpoint)
    }

    private var localIPv4: LocalIPv4? {
        guard let host = localAddress?.replacingOccurrences(of: "::ffff:", with: "") else { return nil }
        return LocalIPv4.snapshot().first { $0.host == host }
    }

    public var localLinkSpeedMbps: Int? {
        localIPv4.flatMap { LocalIPv4.linkSpeedMbps(forInterface: $0.interface) }
    }

    public func effectiveLinkKind(receiverIngress: LinkKind) -> LinkKind {
        if let local = localIPv4 {
            let hardware = LocalIPv4.hardwareKinds()
            let kind = hardware[local.interface] == .wifi ? .wifi : local.kind(hardware: hardware)
            if let kind {
                return EndpointRanker.effectiveLinkKind(localEgress: kind, receiverIngress: receiverIngress)
            }
        }
        let path = connection.currentPath
        let egress: LinkKind? = switch path {
        case let path? where path.usesInterfaceType(.wifi): .wifi
        case let path? where path.usesInterfaceType(.wiredEthernet): .wiredEthernet
        default: nil
        }
        return EndpointRanker.effectiveLinkKind(localEgress: egress, receiverIngress: receiverIngress)
    }

    public init(candidate: EndpointCandidate) {
        connection = NWConnection(
            host: NWEndpoint.Host(candidate.host), port: NWEndpoint.Port(rawValue: candidate.port) ?? .any,
            using: Self.tcpParameters()
        )
        smoothedRTT = candidate.rttMs
        roundTripMs = candidate.rttMs
    }

    init(connection: NWConnection) { self.connection = connection }

    static func tcpParameters() -> NWParameters {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    public func start(heartbeats: Bool = true) {
        MediaQueue.sync {
            guard !started, !closed else { return }
            started = true
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state, heartbeats: heartbeats) }
            connection.start(queue: MediaQueue.queue)
            let timer = DispatchSource.makeTimerSource(queue: MediaQueue.queue)
            timer.schedule(deadline: .now() + .milliseconds(750), repeating: .milliseconds(750))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastHeartbeatNs >= 3_000_000_000 {
                    close(reason: ready ? "Heartbeat timed out" : "Connection timed out")
                } else if ready && heartbeats {
                    ping(timestamp: now)
                }
            }
            heartbeatTimer = timer
            timer.resume()
        }
    }

    public func send(_ message: WireMessage) {
        MediaQueue.sync { enqueue(message, completion: nil) }
    }

    private func enqueue(_ message: WireMessage, completion: (@Sendable () -> Void)?) {
        guard !closed else { return }
        do {
            let bytes = try message.frame(sequence: sequence).encoded()
            sequence &+= 1
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                if let error { self?.close(reason: error.localizedDescription) }
            })
            if let completion {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in completion() })
            }
        } catch {
            close(reason: error.localizedDescription)
        }
    }

    func ping(timestamp: UInt64) {
        send(.heartbeat(Heartbeat(timestampNs: timestamp, isReply: false)))
    }

    public func configureCursor(port: UInt16?) {
        MediaQueue.sync {
            cursorConnection?.cancel()
            cursorConnection = nil
            guard !closed, let port, let nwPort = NWEndpoint.Port(rawValue: port), let remoteAddress else { return }
            let cursor = NWConnection(host: NWEndpoint.Host(remoteAddress), port: nwPort, using: .udp)
            cursorConnection = cursor
            cursor.start(queue: MediaQueue.queue)
        }
    }

    public func sendCursor(_ position: CursorPosition) {
        MediaQueue.sync {
            guard let cursorConnection, case .ready = cursorConnection.state else {
                send(.cursorPosition(position))
                return
            }
            cursorConnection.send(content: position.encoded(), completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.configureCursor(port: nil)
                    self?.send(.cursorPosition(position))
                }
            })
        }
    }

    public func disconnect(reason: String = "Disconnected") {
        MediaQueue.sync {
            guard ready else { close(reason: reason); return }
            enqueue(.disconnect(DisconnectReason(reason: reason))) { [weak self] in self?.close(reason: reason) }
        }
    }

    public func close(reason: String = "Connection closed") {
        MediaQueue.sync {
            guard !closed else { return }
            closed = true
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            cursorConnection?.cancel()
            cursorConnection = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            let callback = onClose
            onMessage = nil
            onClose = nil
            onReady = nil
            onRTT = nil
            callback?(reason)
        }
    }

    private func handle(_ state: NWConnection.State, heartbeats: Bool) {
        guard !closed else { return }
        switch state {
        case .ready where !ready:
            ready = true
            lastHeartbeatNs = DispatchTime.now().uptimeNanoseconds
            receive()
            onReady?()
            if heartbeats { ping(timestamp: lastHeartbeatNs) }
        case .failed(let error): close(reason: error.localizedDescription)
        case .cancelled: close()
        default: break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, eof, error in
            guard let self, !closed else { return }
            do {
                if let data {
                    for frame in try reader.append(data) {
                        guard !closed else { return }
                        try handle(WireMessage(frame: frame))
                    }
                }
            } catch {
                close(reason: error.localizedDescription)
                return
            }
            if eof || error != nil {
                close(reason: error?.localizedDescription ?? "Peer closed the TCP stream")
            } else {
                receive()
            }
        }
    }

    private func handle(_ message: WireMessage) throws {
        switch message {
        case .heartbeat(let beat):
            let now = DispatchTime.now().uptimeNanoseconds
            lastHeartbeatNs = now
            if beat.isReply {
                guard beat.timestampNs <= now, now - beat.timestampNs < 3_000_000_000 else { return }
                let rtt = Double(now - beat.timestampNs) / 1_000_000
                smoothedRTT = smoothedRTT.map { $0 * 0.75 + rtt * 0.25 } ?? rtt
                roundTripMs = rtt
                onRTT?(rtt)
            } else {
                send(.heartbeat(Heartbeat(timestampNs: beat.timestampNs, isReply: true)))
            }
        case .disconnect(let reason): close(reason: reason.reason)
        default: onMessage?(message)
        }
    }

    static func address(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        return "\(host)"
    }

    deinit {
        heartbeatTimer?.cancel()
        cursorConnection?.cancel()
        connection.cancel()
    }
}
