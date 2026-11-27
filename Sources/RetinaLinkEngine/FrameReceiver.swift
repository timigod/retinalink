import CoreVideo
import Foundation
import RetinaLinkCore

public enum ReceivedFrame: Sendable {
    case hevc(VideoFrame)
    case lossless(LosslessFrame)

    public var frameID: UInt64 {
        switch self {
        case .hevc(let frame): frame.frameID
        case .lossless(let frame): frame.frameID
        }
    }
}

public final class FrameReceiver: @unchecked Sendable {
    @MediaValue private var _onConfig: (@Sendable (SenderConfig) -> Void)?
    public var onConfig: (@Sendable (SenderConfig) -> Void)? {
        get { _onConfig }
        set { _onConfig = newValue }
    }
    @MediaValue private var _onFrame: (@Sendable (SenderConfig, TransportSession, ReceivedFrame, DecodedVideoFrame) -> Void)?
    public var onFrame: (@Sendable (SenderConfig, TransportSession, ReceivedFrame, DecodedVideoFrame) -> Void)? {
        get { _onFrame }
        set { _onFrame = newValue }
    }
    @MediaValue private var _onCursorImage: (@Sendable (CursorImage) -> Void)?
    public var onCursorImage: (@Sendable (CursorImage) -> Void)? {
        get { _onCursorImage }
        set { _onCursorImage = newValue }
    }
    @MediaValue private var _onCursorPosition: (@Sendable (CursorPosition) -> Void)?
    public var onCursorPosition: (@Sendable (CursorPosition) -> Void)? {
        get { _onCursorPosition }
        set { _onCursorPosition = newValue }
    }
    @MediaValue private var _onDisconnect: (@Sendable () -> Void)?
    public var onDisconnect: (@Sendable () -> Void)? {
        get { _onDisconnect }
        set { _onDisconnect = newValue }
    }
    @MediaValue private var _onError: (@Sendable (String) -> Void)?
    public var onError: (@Sendable (String) -> Void)? {
        get { _onError }
        set { _onError = newValue }
    }
    @MediaValue private var _submittedFrames = 0
    public var submittedFrames: Int { _submittedFrames }
    public var activeSession: TransportSession? { MediaQueue.sync { active?.session } }

    private let hello: ReceiverHello
    private let output: DecoderOutput
    private let acceptsConfig: @Sendable (SenderConfig, TransportSession) -> Bool
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var active: Connection?

    public init(hello: ReceiverHello, output: DecoderOutput = .native,
                acceptsConfig: @escaping @Sendable (SenderConfig, TransportSession) -> Bool) {
        self.hello = hello
        self.output = output
        self.acceptsConfig = acceptsConfig
    }

    public func accept(_ session: TransportSession, cursorPort: UInt16?, addresses: [EndpointCandidate]) {
        MediaQueue.sync {
            guard connections.count < 12 else { session.close(reason: "Receiver connection limit"); return }
            let connection = Connection(session)
            let id = ObjectIdentifier(session)
            connections[id] = connection
            session.onReady = { [weak session, hello] in
                guard let session else { return }
                let ingress = addresses.first { $0.host == session.localAddress }?.kind
                session.send(.receiverHello(ReceiverHello(name: hello.name, panelPixelWidth: hello.panelPixelWidth,
                                                           panelPixelHeight: hello.panelPixelHeight, cursorPort: cursorPort,
                                                           ingressKind: ingress, supportsLossless: hello.supportsLossless,
                                                           losslessVersion: hello.losslessVersion,
                                                           supportedProfiles: hello.supportedProfiles,
                                                           physicalWidthMm: hello.physicalWidthMm,
                                                           physicalHeightMm: hello.physicalHeightMm,
                                                           panelIsHiDPI: hello.panelIsHiDPI)))
            }
            session.onMessage = { [weak self, weak connection] message in
                guard let self, let connection else { return }
                receive(message, connection: connection)
            }
            session.onClose = { [weak self, weak connection] _ in
                guard let self, let connection else { return }
                connections[id] = nil
                if active === connection {
                    active = nil
                    onDisconnect?()
                }
            }
            MediaQueue.queue.asyncAfter(deadline: .now() + .seconds(4)) { [weak connection] in
                guard let connection, connection.config == nil else { return }
                connection.session.close(reason: "No sender configuration")
            }
            session.start()
        }
    }

    public func receiveCursor(_ position: CursorPosition, from address: String) {
        MediaQueue.sync {
            guard let active, active.session.remoteAddress == address, active.config?.cursorMode == .overlay else { return }
            onCursorPosition?(position)
        }
    }

    public func dropConnections() {
        MediaQueue.sync {
            for connection in Array(connections.values) { connection.session.close(reason: "Receiver stopped") }
        }
    }

    func dismissOverlay() {
        MediaQueue.sync {
            active = nil
            for connection in Array(connections.values) {
                connection.superseded = true
                connection.session.disconnect(reason: Self.overlayDismissed)
            }
        }
    }

    static let overlayDismissed = "Receiver dismissed the overlay"

    private func receive(_ message: WireMessage, connection: Connection) {
        let session = connection.session
        switch message {
        case .senderConfig(let config):
            guard connection.config == nil,
                  (16...8192).contains(config.width), (16...8192).contains(config.height),
                  config.width == hello.panelPixelWidth, config.height == hello.panelPixelHeight,
                  hello.supportedProfiles?.contains(config.profile) != false,
                  acceptsConfig(config, session) else {
                session.disconnect(reason: "Sender configuration was rejected")
                return
            }
            connection.config = config
            connection.decoder = HEVCDecoder(config: config, output: output)
            onConfig?(config)
        case .videoFrame(let video):
            guard let config = connection.config, let decoder = connection.decoder,
                  video.frameID > connection.lastSubmittedFrameID else { return }
            guard !connection.needsKeyframe || video.isKeyframe && !video.hvcC.isEmpty else {
                // This frame was in flight before the resynchronization
                // request. Release the sender's slot without presenting it.
                acknowledge(video, decodeUs: 0, on: session)
                return
            }
            connection.lastHEVCFrameID = video.frameID
            _submittedFrames += 1
            connection.lastSubmittedFrameID = video.frameID
            connection.needsKeyframe = false
            let generation = connection.decoderGeneration
            do {
                try decoder.decode(video) { [weak self, weak connection] result in
                    MediaQueue.queue.async { [weak self, weak connection] in
                        guard let self, let connection else { return }
                        guard connection.decoderGeneration == generation else {
                            self.acknowledge(video, decodeUs: 0, on: connection.session)
                            return
                        }
                        self.decoded(result, video: video, config: config, connection: connection)
                    }
                }
            } catch {
                decodeFailed(error, video: video, config: config, connection: connection)
            }
        case .losslessFrame(let frame):
            receiveLossless(frame, connection: connection)
        case .cursorImage(let image):
            guard connection.config?.cursorMode == .overlay else { return }
            connection.cursorImage = image
            if connection === active { onCursorImage?(image) }
        case .cursorPosition(let position):
            guard connection.config?.cursorMode == .overlay else { return }
            connection.cursorPosition = position
            if connection === active { onCursorPosition?(position) }
        default: break
        }
    }

    private func receiveLossless(_ frame: LosslessFrame, connection: Connection) {
        guard hello.supportsProgressiveLossless, let config = connection.config,
              frame.frameID > connection.lastSubmittedFrameID, !connection.superseded else { return }
        connection.lastSubmittedFrameID = frame.frameID
        _submittedFrames += 1
        guard active === connection, !connection.needsKeyframe, frame.width == config.width,
              frame.height == config.height, connection.pendingLossless < 6 else {
            rejectLossless(frame, connection: connection)
            return
        }
        if connection.lossless == nil {
            connection.lossless = LosslessWork(config: config)
        }
        guard let work = connection.lossless else { return }
        connection.pendingLossless += 1
        let epoch = connection.losslessEpoch
        work.queue.async { [weak self, weak connection] in
            let outcome = work.decode(frame)
            MediaQueue.queue.async { [weak self, weak connection] in
                guard let self, let connection else { return }
                connection.pendingLossless -= 1
                guard self.active === connection,
                      self.connections[ObjectIdentifier(connection.session)] === connection else { return }
                guard connection.losslessEpoch == epoch else {
                    self.acknowledgeLossless(frame, decodeUs: 0, on: connection.session)
                    return
                }
                switch outcome {
                case .applied(let decodeUs, let decoded):
                    self.acknowledgeLossless(frame, decodeUs: decodeUs, on: connection.session)
                    guard let decoded, frame.frameID > connection.lastPresentedFrameID,
                          frame.frameID > connection.lastHEVCFrameID else { return }
                    connection.lastPresentedFrameID = frame.frameID
                    self.onFrame?(config, connection.session, .lossless(frame), decoded)
                case .rejected(let reason):
                    self.onError?(reason)
                    self.rejectLossless(frame, connection: connection)
                }
            }
        }
    }

    private func resetLossless(_ connection: Connection) {
        guard let work = connection.lossless else { return }
        connection.losslessEpoch &+= 1
        work.queue.async { work.reset() }
    }

    private func rejectLossless(_ frame: LosslessFrame, connection: Connection) {
        resetLossless(connection)
        connection.needsKeyframe = true
        acknowledgeLossless(frame, decodeUs: 0, on: connection.session)
        connection.session.send(.requestKeyframe)
    }

    private func acknowledgeLossless(_ frame: LosslessFrame, decodeUs: UInt32, on session: TransportSession) {
        session.send(.frameAck(FrameAck(frameID: frame.frameID, captureTimeNs: frame.captureTimeNs,
                                        decodeUs: decodeUs, receivedBytes: UInt32(clamping: frame.payloadBytes))))
    }

    private final class LosslessWork: @unchecked Sendable {
        let queue = DispatchQueue(label: "RetinaLink.lossless.decode", qos: .userInitiated)
        let config: SenderConfig
        private var decoder: LosslessDecoder?

        init(config: SenderConfig) { self.config = config }

        func reset() { decoder?.reset() }

        func decode(_ frame: LosslessFrame) -> LosslessDecoder.Outcome {
            if let decoder { return decoder.decodeFrame(frame) }
            guard let decoder = LosslessDecoder.make(width: Int(config.width), height: Int(config.height),
                                                     colorSpace: config.colorSpace) else {
                return .rejected("Could not create lossless display buffer pool")
            }
            self.decoder = decoder
            return decoder.decodeFrame(frame)
        }
    }

    private func decoded(_ result: Result<DecodedVideoFrame, Error>, video: VideoFrame, config: SenderConfig,
                         connection: Connection) {
        guard connections[ObjectIdentifier(connection.session)] === connection, !connection.superseded else { return }
        switch result {
        case .success(let decoded):
            let buffer = decoded.surface.pixelBuffer
            guard CVPixelBufferGetWidth(buffer) == video.width, CVPixelBufferGetHeight(buffer) == video.height else {
                decodeFailed(RetinaLinkError.operation("Decoder returned a different pixel size"),
                             video: video, config: config, connection: connection)
                return
            }
            connection.consecutiveFailures = 0
            acknowledge(video, decodeUs: decoded.decodeUs, on: connection.session)
            let changedSession = active !== connection
            guard (!changedSession || video.isKeyframe), video.frameID > connection.lastPresentedFrameID else { return }
            connection.lastPresentedFrameID = video.frameID
            if changedSession {
                let previous = active
                active = connection
                previous?.superseded = true
                previous?.session.disconnect(reason: "Receiver switched routes")
            }
            onFrame?(config, connection.session, .hevc(video), decoded)
            if changedSession {
                if let image = connection.cursorImage { onCursorImage?(image) }
                if let position = connection.cursorPosition { onCursorPosition?(position) }
            }
        case .failure(let error):
            decodeFailed(error, video: video, config: config, connection: connection)
        }
    }

    private func decodeFailed(_ error: Error, video: VideoFrame, config: SenderConfig, connection: Connection) {
        onError?(error.localizedDescription)
        connection.consecutiveFailures += 1
        if connection.consecutiveFailures >= 2 {
            connection.session.disconnect(reason: error.localizedDescription)
            return
        }
        connection.needsKeyframe = true
        connection.decoderGeneration += 1
        connection.decoder = HEVCDecoder(config: config, output: output)
        connection.session.send(.requestKeyframe)
        acknowledge(video, decodeUs: 0, on: connection.session)
    }

    private func acknowledge(_ frame: VideoFrame, decodeUs: UInt32, on session: TransportSession) {
        session.send(.frameAck(FrameAck(frameID: frame.frameID, captureTimeNs: frame.captureTimeNs,
                                        decodeUs: decodeUs,
                                        receivedBytes: UInt32(clamping: 28 + frame.hvcC.count + frame.nalUnits.count))))
    }

    private final class Connection: @unchecked Sendable {
        let session: TransportSession
        var config: SenderConfig?
        var decoder: HEVCDecoder?
        var lossless: LosslessWork?
        var pendingLossless = 0
        var lastHEVCFrameID: UInt64 = 0
        var losslessEpoch: UInt64 = 0
        var needsKeyframe = true
        var superseded = false
        var decoderGeneration = 0
        var lastSubmittedFrameID: UInt64 = 0
        var lastPresentedFrameID: UInt64 = 0
        var consecutiveFailures = 0
        var cursorImage: CursorImage?
        var cursorPosition: CursorPosition?

        init(_ session: TransportSession) { self.session = session }
    }
}
