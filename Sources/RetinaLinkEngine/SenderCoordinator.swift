import AppKit
import Combine
@_exported import RetinaLinkCore

public enum SenderConnectionState: Equatable, Sendable {
    case searching
    case ready(peerName: String)
    case connecting(peerName: String)
    case connected(peerName: String, linkKind: LinkKind)
    case reconnecting(peerName: String)
    case permissionRequired
    case error(String)
}

public struct StreamStats: Equatable, Sendable {
    public var pixelWidth: Int = 0
    public var pixelHeight: Int = 0
    public var logicalWidth: Int = 0
    public var logicalHeight: Int = 0
    public var fps: Double = 0
    public var rttMs: Double = 0
    public var encodeMs: Double = 0
    public var decodeMs: Double = 0
    public var bitrateMbps: Double = 0
    public var linkKind: LinkKind = .wifi
    public var isLosslessSettled: Bool = false
    public var linkSpeedMbps: Int? = nil
    public var codecLabel: String = "HEVC 4:4:4"

    public init() {}
}

@MainActor
public final class SenderCoordinator: ObservableObject {
    @Published public private(set) var state: SenderConnectionState = .searching
    @Published public private(set) var peers: [DiscoveredPeer] = []
    @Published public private(set) var selectedPeerID: String?
    @Published public private(set) var presets: [HiDPIPreset] = []
    @Published public private(set) var selectedPresetIndex = 0
    @Published public private(set) var stats = StreamStats()
    @Published public var autoConnect = UserDefaults.standard.bool(forKey: "retinalink.autoConnect") {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "retinalink.autoConnect")
            if autoConnect {
                autoConnectSuppressed = false
                considerPeers()
            }
        }
    }
    @Published public var launchAtLogin = LoginItem.enabled {
        didSet { LoginItem.set(launchAtLogin) }
    }
    @Published public private(set) var hasScreenRecordingPermission = false

    private let discovery = LinkDiscovery()
    private let capture = ScreenCapturePipeline()
    private let display = VirtualDisplayController()
    private let cursor = CursorTracker()
    private let hostName = Host.current().localizedName ?? "Mac"
    private var wakeNotifications: Task<Void, Never>?
    private var sleeping = false
    private var resumePeerID: String?
    private var routeTask: Task<Void, Never>?
    private var routeRefreshPending = false
    private var graceTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var frameSender: FrameSender?
    private var selectedPeer: DiscoveredPeer?
    private var activeCandidate: EndpointCandidate?
    private var startedCandidate: EndpointCandidate?
    private var running = false
    private var autoConnectSuppressed = false
    private var measurementStart = DispatchTime.now().uptimeNanoseconds

    public init() {}

    public func start() {
        guard !running else { return }
        running = true
        refreshPermissionStatus()
        display.onSleep = { [weak self] in
            guard let self else { return }
            self.sleeping = true
            self.resumePeerID = self.selectedPeerID
            self.stopStream()
            self.refreshIdleState()
        }
        wakeNotifications = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                guard let self else { return }
                self.sleeping = false
                self.considerPeers()
            }
        }
        discovery.onPeers = { [weak self] peers in
            self?.peers = peers
            self?.considerPeers()
        }
        discovery.onPathChange = { [weak self] in self?.considerPeers() }
        discovery.onError = { [weak self] reason in
            guard let self, self.frameSender == nil else { return }
            self.state = .error(reason)
        }
        discovery.start()
    }

    public func connect(to peerID: String? = nil) {
        if !running { start() }
        refreshPermissionStatus()
        guard hasScreenRecordingPermission else { return }
        let peer = peerID.flatMap { id in peers.first { $0.id == id } }
            ?? (peerID == nil ? peers.first : nil)
        guard let peer, !sleeping else { return }
        if resumePeerID != peer.id { resumePeerID = nil }
        if selectedPeerID == peer.id, case .connected = state { return }
        stopStream()
        autoConnectSuppressed = false
        selectedPeerID = peer.id
        selectedPeer = peer
        state = .connecting(peerName: peer.name)
        chooseRoute()
    }

    public func disconnect() {
        autoConnectSuppressed = true
        resumePeerID = nil
        stopStream()
        refreshIdleState()
    }

    public func selectPreset(at index: Int) {
        guard presets.indices.contains(index), index != selectedPresetIndex else { return }
        do {
            try display.apply(preset: presets[index])
            selectedPresetIndex = index
            if let selectedPeer {
                UserDefaults.standard.set(presets[index].id, forKey: Self.presetKey(for: selectedPeer))
            }
            stats.logicalWidth = presets[index].logicalWidth
            stats.logicalHeight = presets[index].logicalHeight
        } catch {
            stopStream()
            state = .error(error.localizedDescription)
        }
    }

    public func refreshPermissionStatus() {
        hasScreenRecordingPermission = ScreenCapturePipeline.hasScreenRecordingPermission()
        if !hasScreenRecordingPermission || selectedPeer == nil { refreshIdleState() }
    }

    public func requestScreenRecordingPermission() {
        ScreenCapturePipeline.requestScreenRecordingPermission()
        refreshPermissionStatus()
        considerPeers()
    }

    public func openScreenRecordingSettings() { ScreenCapturePipeline.openScreenRecordingSettings() }

    public func shutdown() {
        running = false
        wakeNotifications?.cancel()
        wakeNotifications = nil
        sleeping = false
        resumePeerID = nil
        discovery.stop()
        stopStream()
        peers = []
        refreshIdleState()
    }

    private func considerPeers() {
        guard running, !sleeping, hasScreenRecordingPermission else { return }
        if let selectedPeer {
            if let refreshed = peers.first(where: { $0.id == selectedPeer.id }) { self.selectedPeer = refreshed }
            chooseRoute()
        } else if let resumePeerID, peers.contains(where: { $0.id == resumePeerID }) {
            connect(to: resumePeerID)
        } else if !autoConnectSuppressed, autoConnect, let peer = peers.first {
            connect(to: peer.id)
        } else if case .error = state {
            if !peers.isEmpty { refreshIdleState() }
        } else {
            refreshIdleState()
        }
    }

    private func chooseRoute() {
        guard let selectedPeer else { return }
        guard routeTask == nil else {
            routeRefreshPending = true
            return
        }
        routeTask = Task { [weak self] in await self?.probeAndConnect(selectedPeer) }
    }

    private func probeAndConnect(_ peer: DiscoveredPeer) async {
        defer {
            if !Task.isCancelled {
                routeTask = nil
                if routeRefreshPending {
                    routeRefreshPending = false
                    chooseRoute()
                }
            }
        }
        repeat {
            let current = selectedPeer ?? peer
            let reachable = await LinkDiscovery.probe(current.candidates)
            guard !Task.isCancelled, self.selectedPeer?.id == peer.id else { return }
            for candidate in reachable where allows(candidate) {
                do {
                    let (session, hello) = try await SenderHandshake.open(candidate: candidate)
                    guard !Task.isCancelled, self.selectedPeer?.id == peer.id else { session.close(); return }
                    do {
                        try attach(session, hello: hello, peer: current, candidate: candidate)
                        return
                    } catch {
                        session.close()
                        if frameSender == nil {
                            stopStream()
                            state = .error(error.localizedDescription)
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                }
            }

            if graceTask == nil {
                if frameSender == nil {
                    stopStream()
                    state = .error("Could not reach \(peer.name)")
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        } while !Task.isCancelled
    }

    private func allows(_ candidate: EndpointCandidate) -> Bool {
        if startedCandidate != nil { return false }
        if let activeCandidate { return candidate.kind > activeCandidate.kind }
        return true
    }

    private func attach(_ session: TransportSession, hello: ReceiverHello,
                        peer: DiscoveredPeer, candidate: EndpointCandidate) throws {
        guard hello.panelPixelWidth == peer.panelPixelWidth, hello.panelPixelHeight == peer.panelPixelHeight,
              let width = UInt16(exactly: hello.panelPixelWidth), let height = UInt16(exactly: hello.panelPixelHeight),
              width > 0, height > 0 else {
            throw RetinaLinkError.operation("The receiver reported a different panel resolution")
        }
        let supported = frameSender.map { [$0.profile] } ?? HEVCEncoder.supportedHardwareProfiles()
        guard let profile = HEVCProfile.negotiate(sender: supported, receiver: hello.supportedProfiles) else {
            throw RetinaLinkError.operation("No compatible hardware HEVC profile")
        }
        let config = SenderConfig(name: hostName, width: width, height: height, profile: profile,
                                  colorSpace: .displayP3,
                                  linkKind: session.effectiveLinkKind(receiverIngress: candidate.kind),
                                  cursorMode: .overlay)
        if let frameSender {
            startedCandidate = candidate
            session.configureCursor(port: hello.cursorPort)
            session.send(.senderConfig(config))
            frameSender.attach(session, kind: candidate.kind, receiverSupportsLossless: hello.supportsLossless == true)
            return
        }
        let ladder = HiDPIPreset.ladder(forPanelWidth: Int(width), height: Int(height),
                                       isHiDPI: hello.panelIsHiDPI ?? peer.panelIsHiDPI)
        let saved = UserDefaults.standard.string(forKey: Self.presetKey(for: peer))
        guard let index = ladder.firstIndex(where: { $0.id == saved }) ?? ladder.firstIndex(where: \.isNativeDefault) else {
            throw RetinaLinkError.operation("No display modes for the receiver")
        }
        let frames = try FrameSender(config: config, linkSpeedMbps: session.localLinkSpeedMbps)
        let cap = HiDPIPreset.backingCap(forPanelWidth: Int(width), height: Int(height))
        let physicalWidth = hello.physicalWidthMm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 500
        let physicalHeight = hello.physicalHeightMm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? physicalWidth * Double(height) / Double(width)
        display.configure(name: "\(peer.name) (RetinaLink)", sizeInMillimeters: CGSize(width: physicalWidth, height: physicalHeight),
                          maxPixelsWide: max(Int(width), cap.width), maxPixelsHigh: max(Int(height), cap.height))
        try display.start(preset: ladder[index])
        guard let displayID = display.displayID else { throw RetinaLinkError.operation("Virtual display has no ID") }
        presets = ladder
        selectedPresetIndex = index
        stats = StreamStats()
        stats.pixelWidth = Int(width)
        stats.pixelHeight = Int(height)
        stats.logicalWidth = ladder[index].logicalWidth
        stats.logicalHeight = ladder[index].logicalHeight
        stats.codecLabel = config.profile.codecLabel
        frameSender = frames
        startedCandidate = candidate

        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.rollupStats()
            }
        }
        frames.onError = { [weak self, weak frames] error in
            DispatchQueue.main.async {
                guard let self, let frames, self.frameSender === frames else { return }
                self.stopStream()
                self.state = .error(error.localizedDescription)
            }
        }
        frames.onSwitch = { [weak self, weak frames] session, kind in
            let badge = session.effectiveLinkKind(receiverIngress: kind)
            DispatchQueue.main.async {
                guard let self, let frames, self.frameSender === frames else { return }
                self.resumePeerID = nil
                self.activeCandidate = self.startedCandidate
                self.startedCandidate = nil
                self.graceTask?.cancel()
                self.graceTask = nil
                self.stats.linkKind = badge
                self.state = .connected(peerName: peer.name, linkKind: badge)
                if (self.peers.first { $0.id == peer.id }?.bestKnownLink ?? kind) > kind { self.chooseRoute() }
            }
        }
        frames.onLinkLost = { [weak self, weak frames] reason in
            DispatchQueue.main.async {
                guard let self, let frames, self.frameSender === frames else { return }
                if reason == FrameReceiver.overlayDismissed { self.disconnect() }
                else { self.reconnect(peer: peer, reason: reason) }
            }
        }
        frames.onPendingLinkLost = { [weak self, weak frames] in
            DispatchQueue.main.async {
                guard let self, let frames, self.frameSender === frames else { return }
                self.startedCandidate = nil
            }
        }
        session.configureCursor(port: hello.cursorPort)
        session.send(.senderConfig(config))
        frames.attach(session, kind: candidate.kind, receiverSupportsLossless: hello.supportsLossless == true)
        cursor.start(displayID: displayID, onImage: { [weak frames] in frames?.sendCursorImage($0) },
                     onPosition: { [weak frames] in frames?.sendCursorPosition($0) })
        Task { [weak self, weak frames, capture] in
            guard let self, let frames, frameSender === frames else { return }
            do {
                try await capture.start(displayID: displayID, width: Int(width), height: Int(height),
                                        cursorMode: config.cursorMode, onFrame: { [weak frames] surface, time, dirty in
                    frames?.submit(surface, captureTimeNs: time, dirtyRects: dirty)
                }, onError: { [weak self, weak frames] error in
                    DispatchQueue.main.async {
                        guard let self, let frames, self.frameSender === frames else { return }
                        self.stopStream()
                        self.state = .error(error.localizedDescription)
                    }
                })
            } catch {
                guard frameSender === frames else { return }
                stopStream()
                state = .error(error.localizedDescription)
            }
        }
    }

    private static func presetKey(for peer: DiscoveredPeer) -> String {
        "retinalink.preset.\(peer.name).\(peer.panelPixelWidth)x\(peer.panelPixelHeight)"
    }

    private func reconnect(peer: DiscoveredPeer, reason: String) {
        guard selectedPeerID == peer.id else { return }
        activeCandidate = nil
        startedCandidate = nil
        routeTask?.cancel()
        routeTask = nil
        routeRefreshPending = false
        state = .reconnecting(peerName: peer.name)
        if graceTask == nil {
            graceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                stopStream()
                state = .error(reason)
            }
        }
        chooseRoute()
    }

    private func stopStream() {
        routeTask?.cancel()
        routeTask = nil
        routeRefreshPending = false
        graceTask?.cancel()
        graceTask = nil
        statsTask?.cancel()
        statsTask = nil
        cursor.stop()
        frameSender?.stop()
        frameSender = nil
        Task { [capture] in await capture.stop() }
        display.stop()
        selectedPeer = nil
        selectedPeerID = nil
        activeCandidate = nil
        startedCandidate = nil
        presets = []
        selectedPresetIndex = 0
        stats = StreamStats()
        measurementStart = DispatchTime.now().uptimeNanoseconds
    }

    private func refreshIdleState() {
        if !hasScreenRecordingPermission { state = .permissionRequired }
        else if let peer = peers.first { state = .ready(peerName: peer.name) }
        else { state = .searching }
    }

    private func rollupStats() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - measurementStart) / 1_000_000_000
        guard elapsed > 0, let frameSender else { return }
        let slice = frameSender.takeStats()
        stats.fps = Double(slice.frames) / elapsed
        stats.bitrateMbps = Double(slice.bytes) * 8e-6 / elapsed
        stats.rttMs = frameSender.roundTripMs ?? 0
        stats.isLosslessSettled = frameSender.isLosslessSettled
        stats.linkSpeedMbps = frameSender.linkSpeedMbps
        if let latest = slice.last {
            stats.encodeMs = Double(latest.encodeUs) / 1000
            stats.decodeMs = Double(latest.decodeUs) / 1000
        }
        measurementStart = now
    }

    deinit {
        wakeNotifications?.cancel()
        routeTask?.cancel()
        graceTask?.cancel()
        statsTask?.cancel()
        Task { [capture] in await capture.stop() }
    }
}
