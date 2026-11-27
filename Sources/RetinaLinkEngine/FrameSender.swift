import CoreGraphics
import CoreVideo
import Foundation
import RetinaLinkCore

public struct FrameMeasurement: Sendable {
    public let encodeUs: UInt32
    public let decodeUs: UInt32
    public let deliveryMs: Double
    public let receivedBytes: UInt32
}

public final class FrameSender: @unchecked Sendable {
    @MediaValue private var _onMeasurement: (@Sendable (FrameMeasurement) -> Void)?
    public var onMeasurement: (@Sendable (FrameMeasurement) -> Void)? {
        get { _onMeasurement }
        set { _onMeasurement = newValue }
    }
    @MediaValue private var _onError: (@Sendable (Error) -> Void)?
    public var onError: (@Sendable (Error) -> Void)? {
        get { _onError }
        set { _onError = newValue }
    }
    @MediaValue private var _onSwitch: (@Sendable (TransportSession, LinkKind) -> Void)?
    public var onSwitch: (@Sendable (TransportSession, LinkKind) -> Void)? {
        get { _onSwitch }
        set { _onSwitch = newValue }
    }
    @MediaValue private var _onLinkLost: (@Sendable (String) -> Void)?
    public var onLinkLost: (@Sendable (String) -> Void)? {
        get { _onLinkLost }
        set { _onLinkLost = newValue }
    }
    @MediaValue var onPendingLinkLost: (@Sendable () -> Void)?
    @MediaValue private var _droppedFrames = 0
    public var droppedFrames: Int { _droppedFrames }
    @MediaValue private var _submittedFrames = 0
    public var submittedFrames: Int { _submittedFrames }
    @MediaValue private var _encodedFrames = 0
    public var encodedFrames: Int { _encodedFrames }
    @MediaValue private var _inFlight = 0
    public var inFlight: Int { _inFlight }
    @MediaValue private var _peakInFlight = 0
    public var peakInFlight: Int { _peakInFlight }
    @MediaValue private var _activeKind: LinkKind?
    public var activeKind: LinkKind? { _activeKind }
    public var roundTripMs: Double? { MediaQueue.sync { active?.session.roundTripMs } }

    private var readings = StatsSlice()

    struct StatsSlice {
        var frames = 0
        var bytes = 0
        var last: FrameMeasurement?
    }

    func takeStats() -> StatsSlice {
        MediaQueue.sync {
            let slice = readings
            readings = StatsSlice()
            return slice
        }
    }

    public let profile: HEVCProfile
    public var isLosslessSettled: Bool { MediaQueue.sync { settledFrameID != nil } }
    public var linkSpeedMbps: Int? { MediaQueue.sync { active?.linkSpeedMbps } }

    private let losslessQueue = DispatchQueue(label: "RetinaLink.lossless", qos: .userInitiated)
    private var captureGeneration: UInt64 = 0
    private var settledFrameID: UInt64?
    private var stagingFrameID: UInt64?
    private var stagingTileHashes: [UInt64?] = []
    private var transfer: LosslessTransfer?
    private var settleTimer: DispatchWorkItem?
    private var lastCaptureTime: UInt64 = 0
    private var losslessJob: UInt64?
    private var attemptedSettle: UInt64?
    private let encoder: HEVCEncoder
    private var active: Route?
    private var pending: Route?
    private var retiring: Route?
    private var needsKeyframe = true
    private var lastSurface: VideoSurface?
    private var lastCursorImage: CursorImage?
    private var lastCursorPosition: CursorPosition?
    private var nextFrameID: UInt64 = 1
    private var generation = 0
    private var sent: [UInt64: Outstanding] = [:]
    private var order: [UInt64] = []
    private var completed: [UInt64: Result<EncodedVideoFrame, Error>] = [:]
    private var adaptationStarted = DispatchTime.now().uptimeNanoseconds
    private var acceptedAtLastUpdate = 0
    private var droppedAtLastUpdate = 0

    public init(config: SenderConfig, linkSpeedMbps: Int? = nil) throws {
        profile = config.profile
        encoder = try HEVCEncoder(width: config.width, height: config.height, profile: config.profile,
                                  colorSpace: config.colorSpace,
                                  bitrateMbps: BitrateController(linkKind: config.linkKind, linkSpeedMbps: linkSpeedMbps).bitrateMbps)
    }

    public func attach(_ session: TransportSession, kind: LinkKind, receiverSupportsLossless: Bool = false) {
        MediaQueue.sync {
            if let pending { detach(pending, reason: "Superseded route") }
            let route = Route(session: session, kind: kind, receiverSupportsLossless: receiverSupportsLossless)
            if active == nil {
                active = route
                _activeKind = kind
                try? encoder.updateBitrate(route.bitrate.targetMbps)
                sendCursorSnapshot(on: route)
            } else {
                pending = route
                route.switchFromFrameID = nextFrameID
            }
            session.onMessage = { [weak self, weak route] message in
                guard let self, let route else { return }
                switch message {
                case .frameAck(let ack): acknowledge(ack, on: route)
                case .requestKeyframe:
                    if active === route {
                        let rejectedLossless = transfer != nil || stagingFrameID != nil
                        resetStaging()
                        requestKeyframe(skipSettleUntilNextCapture: rejectedLossless)
                    } else if pending === route {
                        requestKeyframe()
                    }
                default: break
                }
            }
            session.onClose = { [weak self, weak route] reason in
                guard let self, let route else { return }
                lost(route, reason: reason)
            }
            requestKeyframe()
        }
    }

    public func submit(_ surface: VideoSurface, captureTimeNs: UInt64, dirtyRects: [CGRect] = []) {
        MediaQueue.sync {
            captureGeneration &+= 1
            lastSurface = surface
            lastCaptureTime = captureTimeNs
            guard let active else { return }
            if transfer != nil { cancelTransfer() }
            let limit = BitrateController.maxInFlightFrames(for: active.kind, rttMs: active.session.smoothedRoundTripMs ?? .nan)
            if let base = settledFrameID, losslessJob == nil, pending == nil, inFlight < limit {
                let dirty = DirtyRects(dirtyRects, width: CVPixelBufferGetWidth(surface.pixelBuffer),
                                       height: CVPixelBufferGetHeight(surface.pixelBuffer))
                if dirty.fitsIncrementalBudget {
                    prepareLossless(surface, base: base, dirty: dirty, route: active)
                    return
                }
            }
            resumeMotion(surface, captureTimeNs: captureTimeNs, limit: limit)
        }
    }

    private func resumeMotion(_ surface: VideoSurface, captureTimeNs: UInt64, limit: Int) {
        clearSettle()
        armSettle()
        guard inFlight < limit else {
            _droppedFrames += 1
            return
        }
        encode(surface, captureTimeNs: captureTimeNs)
    }

    private func clearSettle() {
        settledFrameID = nil
        settleTimer?.cancel()
        settleTimer = nil
    }

    private func armSettle() {
        guard settleTimer == nil, settledFrameID == nil, active?.supportsLossless == true, pending == nil,
              !needsKeyframe, lastSurface != nil, transfer == nil, attemptedSettle != captureGeneration else { return }
        let generation = captureGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.captureGeneration == generation else { return }
            self.settleTimer = nil
            guard self.inFlight <= 1, self.order.isEmpty, self.losslessJob == nil,
                  let route = self.active, route.confirmed, let surface = self.lastSurface else { return }
            self.attemptedSettle = generation
            self.prepareLossless(surface, base: self.stagingFrameID ?? 0, dirty: nil, route: route)
        }
        settleTimer = item
        let deadline = DispatchTime(uptimeNanoseconds: lastCaptureTime) + .milliseconds(100)
        MediaQueue.queue.asyncAfter(deadline: deadline, execute: item)
    }

    private func prepareLossless(_ surface: VideoSurface, base: UInt64, dirty: DirtyRects?, route: Route) {
        let id = nextFrameID
        nextFrameID += dirty == nil ? 32 : 1
        losslessJob = id
        let capture = captureGeneration
        let connectionGeneration = generation
        let time = lastCaptureTime
        let hashes = stagingTileHashes
        losslessQueue.async { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let chunks: [LosslessFrame]
            let resultingHashes: [UInt64?]
            if let dirty {
                chunks = LosslessCodec.incremental(surface, frameID: id, captureTimeNs: time, baseFrameID: base,
                                                   dirty: dirty).map { [$0] } ?? []
                let grid = LosslessTileGrid.rectangles(width: CVPixelBufferGetWidth(surface.pixelBuffer),
                                                      height: CVPixelBufferGetHeight(surface.pixelBuffer))
                // A dirty rect writes only part of each touched tile. Until a
                // full tile arrives, its exact receiver-side hash is unknown.
                resultingHashes = zip(grid, hashes).map { tile, hash in
                    dirty.rects.contains(where: tile.overlaps) ? nil : hash
                }
            } else {
                let settle = LosslessCodec.settle(surface, firstFrameID: id, captureTimeNs: time,
                                                  baseFrameID: base, previousHashes: hashes)
                chunks = settle?.chunks ?? []
                resultingHashes = settle?.hashes ?? []
            }
            let elapsed = UInt32(clamping: (DispatchTime.now().uptimeNanoseconds - started) / 1000)
            MediaQueue.queue.async { [weak self] in
                guard let self, self.losslessJob == id else { return }
                self.losslessJob = nil
                guard self.active === route, self.generation == connectionGeneration,
                      self.captureGeneration == capture, self.pending == nil, !self.needsKeyframe else {
                    self.armSettle()
                    return
                }
                guard !chunks.isEmpty else {
                    if dirty != nil {
                        let limit = BitrateController.maxInFlightFrames(for: route.kind,
                            rttMs: route.session.smoothedRoundTripMs ?? .nan)
                        self.resumeMotion(surface, captureTimeNs: time, limit: limit)
                    }
                    return
                }
                self.transfer = LosslessTransfer(chunks: chunks, hashes: resultingHashes, encodeUs: elapsed)
                self.sendNextChunk(on: route)
            }
        }
    }

    private func sendNextChunk(on route: Route) {
        guard let transfer, let frame = transfer.chunks.first else { return }
        _inFlight += 1
        _peakInFlight = max(_peakInFlight, _inFlight)
        _submittedFrames += 1
        sent[frame.frameID] = Outstanding(route: route, captureTimeNs: frame.captureTimeNs,
                                         encodeUs: transfer.encodeUs, isKeyframe: false, isLossless: true)
        route.session.send(.losslessFrame(frame))
    }

    private func acknowledgeLossless(_ ack: FrameAck, on route: Route) {
        guard let transfer, let frame = transfer.chunks.first, frame.frameID == ack.frameID else { return }
        guard ack.decodeUs > 0 else {
            resetStaging()
            requestKeyframe(skipSettleUntilNextCapture: true)
            return
        }
        if frame.present {
            stagingFrameID = frame.frameID
            stagingTileHashes = transfer.hashes
            settledFrameID = frame.frameID
            self.transfer = nil
        } else {
            self.transfer?.chunks.removeFirst()
            sendNextChunk(on: route)
        }
    }

    private func cancelTransfer() {
        guard transfer != nil else { return }
        // One chunk may already have reached the peer. A new complete settle
        // is the only safe base after aborting a partly transmitted image.
        resetStaging()
        clearSettle()
    }

    private func resetStaging() {
        stagingFrameID = nil
        stagingTileHashes.removeAll()
        transfer = nil
    }

    private struct LosslessTransfer {
        var chunks: [LosslessFrame]
        let hashes: [UInt64?]
        let encodeUs: UInt32
    }

    public func sendCursorImage(_ image: CursorImage) {
        MediaQueue.sync {
            lastCursorImage = image
            active?.session.send(.cursorImage(image))
        }
    }

    public func sendCursorPosition(_ position: CursorPosition) {
        MediaQueue.sync {
            lastCursorPosition = position
            active?.session.sendCursor(position)
        }
    }

    public func stop() {
        MediaQueue.sync {
            let routes = [active, pending, retiring].compactMap { $0 }
            active = nil
            pending = nil
            retiring = nil
            _activeKind = nil
            lastSurface = nil
            resetInFlight()
            for route in routes { detach(route, reason: "Sender stopped") }
        }
    }

    private func encode(_ surface: VideoSurface, captureTimeNs: UInt64) {
        let id = nextFrameID
        nextFrameID &+= 1
        let generation = self.generation
        if needsKeyframe {
            encoder.forceKeyframe()
            needsKeyframe = false
        }
        _inFlight += 1
        _peakInFlight = max(_peakInFlight, _inFlight)
        _submittedFrames += 1
        order.append(id)
        armSettle()
        do {
            try encoder.encode(surface, frameID: id, captureTimeNs: captureTimeNs) { [weak self] result in
                MediaQueue.queue.async { [weak self] in self?.complete(result, id: id, generation: generation) }
            }
        } catch {
            complete(.failure(error), id: id, generation: generation)
        }
    }

    private func complete(_ result: Result<EncodedVideoFrame, Error>, id: UInt64, generation: Int) {
        guard self.generation == generation else { return }
        completed[id] = result
        while let first = order.first, let result = completed.removeValue(forKey: first) {
            order.removeFirst()
            switch result {
            case .success(let encoded):
                if let pending, encoded.frame.isKeyframe, first >= pending.switchFromFrameID {
                    if let retiring { detach(retiring, reason: "Route replaced") }
                    retiring = active
                    resetStaging()
                    active = pending
                    _activeKind = pending.kind
                    try? encoder.updateBitrate(pending.bitrate.targetMbps)
                    self.pending = nil
                    sendCursorSnapshot(on: pending)
                }
                if let active {
                    _encodedFrames += 1
                    sent[first] = Outstanding(route: active, captureTimeNs: encoded.frame.captureTimeNs,
                                              encodeUs: encoded.encodeUs, isKeyframe: encoded.frame.isKeyframe,
                                              isLossless: false)
                    active.session.send(.videoFrame(encoded.frame))
                } else {
                    _inFlight -= 1
                }
            case .failure(let error):
                _inFlight -= 1
                onError?(error)
                return
            }
        }
    }

    private func acknowledge(_ ack: FrameAck, on route: Route) {
        guard let sentFrame = sent[ack.frameID], sentFrame.route === route,
              sentFrame.captureTimeNs == ack.captureTimeNs else { return }
        sent[ack.frameID] = nil
        _inFlight -= 1
        let now = DispatchTime.now().uptimeNanoseconds
        let deliveryMs = Double(now - min(now, ack.captureTimeNs)) / 1_000_000
        let measurement = FrameMeasurement(encodeUs: sentFrame.encodeUs, decodeUs: ack.decodeUs,
                                           deliveryMs: deliveryMs, receivedBytes: ack.receivedBytes)
        if ack.decodeUs > 0 {
            if !sentFrame.isLossless || transfer?.chunks.first?.present == true { readings.frames += 1 }
            readings.bytes += Int(ack.receivedBytes)
            readings.last = measurement
        }
        onMeasurement?(measurement)
        if active === route, ack.decodeUs > 0 {
            if !route.confirmed, sentFrame.isKeyframe {
                route.confirmed = true
                if let retiring { detach(retiring, reason: "Upgraded to \(route.kind.displayName)") }
                retiring = nil
                onSwitch?(route.session, route.kind)
            }
            adapt(route, now: now)
        }
        if active === route, sentFrame.isLossless { acknowledgeLossless(ack, on: route) }
        replayForKeyframe()
        armSettle()
    }

    private func adapt(_ route: Route, now: UInt64) {
        let interval = Double(now - adaptationStarted) / 1_000_000_000
        guard interval >= 1, let rtt = route.session.roundTripMs else { return }
        adaptationStarted = now
        let accepted = submittedFrames - acceptedAtLastUpdate
        let dropped = droppedFrames - droppedAtLastUpdate
        acceptedAtLastUpdate = submittedFrames
        droppedAtLastUpdate = droppedFrames
        let congestion = Double(dropped) / Double(max(1, accepted + dropped))
        let target = route.bitrate.update(rttMs: rtt, congestion: congestion, elapsedSeconds: interval)
        try? encoder.updateBitrate(target)
    }

    private func sendCursorSnapshot(on route: Route) {
        if let lastCursorImage { route.session.send(.cursorImage(lastCursorImage)) }
        if let lastCursorPosition { route.session.send(.cursorPosition(lastCursorPosition)) }
    }

    private func requestKeyframe(skipSettleUntilNextCapture: Bool = false) {
        captureGeneration &+= 1
        cancelTransfer()
        if skipSettleUntilNextCapture { attemptedSettle = captureGeneration }
        clearSettle()
        needsKeyframe = true
        replayForKeyframe()
    }

    private func replayForKeyframe() {
        guard needsKeyframe, inFlight == 0, active != nil, let lastSurface else { return }
        encode(lastSurface, captureTimeNs: DispatchTime.now().uptimeNanoseconds)
    }

    private func lost(_ route: Route, reason: String) {
        if retiring === route { retiring = nil }
        if pending === route {
            pending = nil
            onPendingLinkLost?()
        }
        releaseSent(on: route)
        guard active === route else { return }
        if let retiring {
            onPendingLinkLost?()
            active = retiring
            _activeKind = retiring.kind
            self.retiring = nil
            resetInFlight()
            requestKeyframe()
            return
        }
        active = nil
        _activeKind = nil
        resetInFlight()
        if let pending {
            self.pending = nil
            attach(pending.session, kind: pending.kind, receiverSupportsLossless: pending.supportsLossless)
        } else {
            onLinkLost?(reason)
        }
    }

    private func resetInFlight() {
        generation += 1
        resetStaging()
        clearSettle()
        _inFlight = 0
        sent.removeAll()
        order.removeAll()
        completed.removeAll()
        needsKeyframe = true
    }

    private func releaseSent(on route: Route) {
        let dropped = sent.filter { $0.value.route === route }.map(\.key)
        for id in dropped { sent[id] = nil }
        _inFlight -= dropped.count
    }

    private func detach(_ route: Route, reason: String) {
        releaseSent(on: route)
        route.session.onMessage = nil
        route.session.onClose = nil
        route.session.disconnect(reason: reason)
    }

    private struct Outstanding {
        let route: Route
        let captureTimeNs: UInt64
        let encodeUs: UInt32
        let isKeyframe: Bool
        let isLossless: Bool
    }

    private final class Route: @unchecked Sendable {
        let session: TransportSession
        let kind: LinkKind
        var bitrate: BitrateController
        let supportsLossless: Bool
        let linkSpeedMbps: Int?
        var switchFromFrameID: UInt64 = 0
        var confirmed = false

        init(session: TransportSession, kind: LinkKind, receiverSupportsLossless: Bool) {
            self.session = session
            self.kind = kind
            supportsLossless = receiverSupportsLossless
            linkSpeedMbps = session.localLinkSpeedMbps
            bitrate = BitrateController(linkKind: session.effectiveLinkKind(receiverIngress: kind), linkSpeedMbps: linkSpeedMbps)
        }
    }
}
