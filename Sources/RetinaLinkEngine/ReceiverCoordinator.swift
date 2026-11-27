import AppKit
import Combine
import CoreGraphics
import RetinaLinkCore

public enum ReceiverConnectionState: Equatable, Sendable {
    case starting
    case listening(hostName: String, linkSummary: String)
    case streaming(senderName: String, linkKind: LinkKind, resolutionLabel: String)
    case error(String)
}

@MainActor
public final class ReceiverCoordinator: ObservableObject {
    @Published public private(set) var state: ReceiverConnectionState = .starting
    @Published public var launchAtLogin = LoginItem.enabled {
        didSet { LoginItem.set(launchAtLogin) }
    }
    @Published public private(set) var activeAddresses: [EndpointCandidate] = []

    @Published public private(set) var availableDisplays: [ReceiverDisplay] = []
    @Published public private(set) var selectedDisplayID: CGDirectDisplayID = 0

    private var displayChanges: Task<Void, Never>?
    private var advertisedDisplay: ReceiverDisplay?
    private let renderer = DisplayRendererView()
    private var listener: LinkListener?
    private var receiver: FrameReceiver?
    private weak var renderedSession: TransportSession?
    private let hostName = Host.current().localizedName ?? "Mac"

    public init() {
        selectedDisplayID = UInt32(exactly: UserDefaults.standard.integer(forKey: "retinalink.receiverDisplayID")) ?? 0
        refreshDisplays()
    }

    public func selectDisplay(_ displayID: CGDirectDisplayID) {
        guard availableDisplays.contains(where: { $0.id == displayID }), displayID != selectedDisplayID else { return }
        selectedDisplayID = displayID
        UserDefaults.standard.set(Int(displayID), forKey: "retinalink.receiverDisplayID")
        if listener != nil { restartAdvertisement() }
    }

    public func start() {
        if displayChanges == nil {
            displayChanges = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                    guard let self else { return }
                    self.refreshDisplays()
                    if self.renderedSession == nil { self.restartAdvertisement() }
                }
            }
        }
        guard listener == nil else { return }
        state = .starting
        refreshDisplays()
        guard let panel = availableDisplays.first(where: { $0.id == selectedDisplayID }) else {
            state = .error("Could not read the selected display resolution")
            return
        }
        advertisedDisplay = panel
        let listener = LinkListener(name: hostName, width: panel.pixelWidth, height: panel.pixelHeight,
                                    panelIsHiDPI: panel.isHiDPI)
        let size = CGDisplayScreenSize(panel.id)
        let hello = ReceiverHello(name: hostName, panelPixelWidth: panel.pixelWidth, panelPixelHeight: panel.pixelHeight,
                                  cursorPort: nil, supportsLossless: true,
                                  supportedProfiles: HEVCDecoder.supportedHardwareProfiles(),
                                  physicalWidthMm: size.width > 0 ? size.width : nil,
                                  physicalHeightMm: size.height > 0 ? size.height : nil, panelIsHiDPI: panel.isHiDPI)
        let receiver = FrameReceiver(hello: hello) { config, _ in
            !config.name.isEmpty && config.name.utf8.count <= 255
        }
        listener.onListening = { [weak self] _, addresses in
            guard let self else { return }
            self.activeAddresses = addresses
            if self.renderedSession == nil { self.setListening() }
        }
        listener.onSession = { [weak receiver] session, cursorPort, addresses in
            receiver?.accept(session, cursorPort: cursorPort, addresses: addresses)
        }
        listener.onCursor = { [weak receiver] position, address in receiver?.receiveCursor(position, from: address) }
        listener.onError = { [weak self] error in self?.state = .error(error) }
        let presentation = LatestPresentation { [weak self, weak receiver] config, session, surface in
            guard let self, let receiver, self.receiver === receiver,
                  receiver.activeSession === session else { return }
            if self.renderedSession !== session {
                self.renderedSession = session
                self.renderer.resetCursor()
            }
            guard self.renderer.present(surface, colorSpace: config.colorSpace, on: panel.id) else {
                if self.renderer.activePresentationPath == .automatic && !self.renderer.isPreparingScanout {
                    self.state = .error("Could not present the decoded RetinaLink display")
                }
                return
            }
            let state = ReceiverConnectionState.streaming(senderName: config.name, linkKind: config.linkKind,
                                                          resolutionLabel: "\(config.width)×\(config.height)")
            if self.state != state { self.state = state }
        }
        receiver.onFrame = { config, session, _, decoded in
            presentation.enqueue(config, session, decoded.surface)
        }
        receiver.onCursorImage = { [weak self, weak receiver] image in
            DispatchQueue.main.async {
                guard let self, let receiver, self.receiver === receiver else { return }
                self.renderer.setCursorImage(image)
            }
        }
        receiver.onCursorPosition = { [weak self, weak receiver] position in
            DispatchQueue.main.async {
                guard let self, let receiver, self.receiver === receiver else { return }
                self.renderer.setCursorPosition(position)
            }
        }
        receiver.onDisconnect = { [weak self, weak receiver] in
            DispatchQueue.main.async {
                guard let self, let receiver, self.receiver === receiver, receiver.activeSession == nil else { return }
                self.renderedSession = nil
                self.renderer.dismiss()
                self.listener?.clearCursorClients()
                self.setListening()
                self.restartAdvertisement()
            }
        }
        renderer.onEmergencyDismiss = { [weak self] in self?.dismissOverlay() }
        self.listener = listener
        self.receiver = receiver
        do {
            try listener.start()
        } catch {
            shutdown()
            state = .error(error.localizedDescription)
        }
    }

    public func dismissOverlay() {
        receiver?.dismissOverlay()
        renderedSession = nil
        renderer.dismiss()
        listener?.clearCursorClients()
        if listener != nil { setListening() }
    }

    public func shutdown() {
        displayChanges?.cancel()
        displayChanges = nil
        stopListening()
    }

    private func stopListening() {
        dismissOverlay()
        listener?.stop()
        listener = nil
        receiver = nil
        advertisedDisplay = nil
        activeAddresses = []
        state = .starting
    }

    deinit {
        displayChanges?.cancel()
        Task { [renderer] in await renderer.dismiss() }
    }

    private func setListening() {
        let summary = Set(activeAddresses.map(\.kind)).sorted(by: >).map(\.displayName).joined(separator: ", ")
        state = .listening(hostName: hostName, linkSummary: summary)
    }

    private func refreshDisplays() {
        availableDisplays = ReceiverDisplay.allDisplays()
        if !availableDisplays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = availableDisplays.first?.id ?? 0
        }
    }

    private func restartAdvertisement() {
        let selected = availableDisplays.first { $0.id == selectedDisplayID }
        guard selected != advertisedDisplay else { return }
        stopListening()
        start()
    }

}


// Keep at most one presentation queued for AppKit. Decode and ACK continue on
// the media queue even when the main actor misses a compositor refresh.
private final class LatestPresentation: @unchecked Sendable {
    private let show: @MainActor @Sendable (SenderConfig, TransportSession, VideoSurface) -> Void
    private var next: (SenderConfig, TransportSession, VideoSurface)?

    init(show: @escaping @MainActor @Sendable (SenderConfig, TransportSession, VideoSurface) -> Void) {
        self.show = show
    }

    func enqueue(_ config: SenderConfig, _ session: TransportSession, _ surface: VideoSurface) {
        MediaQueue.sync {
            let scheduled = next != nil
            next = (config, session, surface)
            if !scheduled {
                DispatchQueue.main.async { [self] in
                    let frame = MediaQueue.sync {
                        defer { next = nil }
                        return next
                    }
                    if let frame { show(frame.0, frame.1, frame.2) }
                }
            }
        }
    }
}
