import AppKit
import Darwin
import Foundation
import RetinaLinkCore
import RetinaLinkEngine

@main
enum Bench {
    @MainActor static func main() async {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            switch args.command {
            case "codec-probe": CodecProof.run()
            case "lossless-fixture": try LosslessProof.fixture(args)
            case "lossless-sender": try await LosslessProof.send(args)
            case "lossless-receiver": try await LosslessProof.receive(args)
            case "displays":
                for display in ReceiverDisplay.allDisplays() {
                    print("id=\(display.id) name=\(display.name) pixels=\(display.pixelWidth)×\(display.pixelHeight) hidpi=\(display.isHiDPI) main=\(display.isMain)")
                }
            case "verify-virtual-display": try await VirtualDisplayProof.run()
            case "receiver": try await ReceiverBench(args).run()
            case "sender": try await SenderBench(args).run()
            default: throw Arguments.usage
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }
}

struct Arguments {
    let command: String
    let values: [String: String]
    let flags: Set<String>

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw Self.usage }
        self.command = command
        var index = 1
        var flags = Set<String>()
        var values = [String: String]()
        while index < arguments.count {
            let key = arguments[index]
            if ["--discover", "--headless", "--verify-presentation", "--verify-scanout"].contains(key) {
                flags.insert(key)
                index += 1
            } else if ["--host", "--port", "--profile", "--duration", "--output", "--presentation"].contains(key),
                      index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[key] = arguments[index + 1]
                index += 2
            } else {
                throw Self.usage
            }
        }
        self.values = values
        self.flags = flags
    }

    func duration() throws -> Double {
        guard let text = values["--duration"], let seconds = Double(text), (0.25...3600).contains(seconds) else {
            throw Self.usage
        }
        return seconds
    }

    func port(default fallback: UInt16) throws -> UInt16 {
        guard let value = values["--port"] else { return fallback }
        guard let number = UInt16(value) else { throw Self.usage }
        return number
    }

    static let usage = RetinaLinkError.operation("""
        Usage:
          retinalink-bench displays | codec-probe | verify-virtual-display
          retinalink-bench lossless-fixture --output <hash-file>
          retinalink-bench lossless-receiver --headless --port <port> --output <hash-file>
          retinalink-bench lossless-sender --host <ip> --port <port>
          retinalink-bench receiver --duration <seconds> [--headless] [--port 58420] [--output native|bgra] [--presentation automatic|direct|sampleBuffer|metal|metalFloat] [--verify-presentation] [--verify-scanout]
          retinalink-bench sender (--host <ip> | --discover) [--port 58420] --profile hevc444_10|hevc444_8|hevc420_10|hevc420_8 --duration <seconds>
        """)
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

struct Percentiles: Codable {
    let p50: Double?
    let p95: Double?

    init(_ readings: [Double]) {
        let sorted = readings.sorted()
        func sample(_ p: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            return sorted[Int((Double(sorted.count - 1) * p).rounded())]
        }
        p50 = sample(0.50)
        p95 = sample(0.95)
    }
}

@MainActor
final class ReceiverBench {
    struct Summary: Codable {
        let output: DecoderOutput
        let profile: HEVCProfile?
        let pixels: String?
        let presentedFrames: Int
        let presentationMs: Percentiles
        let presentationPath: String?
        let presentationProof: WindowPresentationProof?
        let releasedWindow: Bool
        let scanoutProof: ScanoutProof?
        let linkKind: LinkKind?
        let remoteAddress: String?
        let advertised: [EndpointCandidate]
        let submittedToDecoder: Int
        let decodedFrames: Int
        let sustainedFPS: Double
        let decodeMs: Percentiles
        let megabitsPerSecond: Double
        let hvcC: String?
        let chroma: [ChromaProof]
        let errors: [String]
    }

    private let duration: Double
    private let port: UInt16
    private let output: DecoderOutput
    private let headless: Bool
    private let readings = LockedReadings(ReceiverReadings())
    private var renderer: DisplayRendererView?
    private let presentation: DisplayRendererView.PresentationPath
    private let verifyPresentation: Bool
    private let verifyScanout: Bool
    private var presentingMode: ScanoutProof.Mode?
    private var presentationProof: WindowPresentationProof?
    private var proofTask: Task<Void, Never>?
    private var presentationTimes = [Double]()
    private var presentationName: String?
    private var advertised = [EndpointCandidate]()

    init(_ args: Arguments) throws {
        duration = try args.duration()
        port = try args.port(default: 58420)
        headless = args.flags.contains("--headless")
        guard let output = DecoderOutput(rawValue: args.values["--output"] ?? "native") else {
            throw Arguments.usage
        }
        self.output = output
        guard let presentation = DisplayRendererView.PresentationPath(rawValue: args.values["--presentation"] ?? "automatic") else {
            throw Arguments.usage
        }
        self.presentation = presentation
        verifyScanout = args.flags.contains("--verify-scanout")
        guard !verifyScanout || !headless else { throw Arguments.usage }
        verifyPresentation = verifyScanout || args.flags.contains("--verify-presentation")
    }

    func run() async throws {
        let renderer: DisplayRendererView? = headless ? nil : DisplayRendererView(presentation: presentation)
        self.renderer = renderer
        let originalMode = verifyScanout ? ScanoutProof.Mode.read() : nil
        if !headless { NSApplication.shared.setActivationPolicy(.accessory) }
        let name = "RetinaLink Bench \(Host.current().localizedName ?? "Mac")"
        let listener = LinkListener(name: name, width: TestPattern.width, height: TestPattern.height)
        let hello = ReceiverHello(name: name, panelPixelWidth: TestPattern.width,
                                  panelPixelHeight: TestPattern.height, cursorPort: nil)
        let receiver = FrameReceiver(hello: hello, output: output) { config, _ in
            config.name == "RetinaLink Synthetic Benchmark"
        }
        let meter = ChromaMeter()
        listener.onSession = { [weak receiver] session, port, addresses in
            receiver?.accept(session, cursorPort: port, addresses: addresses)
        }
        listener.onCursor = { [weak receiver] position, address in receiver?.receiveCursor(position, from: address) }
        listener.onListening = { [weak self] port, addresses in
            self?.advertised = addresses
            FileHandle.standardError.write(Data("LISTENING \(port) \(EndpointRanker.encodeAddresses(addresses))\n".utf8))
        }
        let readings = self.readings
        listener.onError = { error in readings.update { $0.errors.append(error); $0.ended = true } }
        receiver.onConfig = { config in readings.update { $0.config = config } }
        receiver.onError = { error in readings.update { $0.errors.append(error) } }
        receiver.onDisconnect = { [weak self] in
            readings.update { $0.ended = true }
            DispatchQueue.main.async { self?.renderer?.dismiss() }
        }
        receiver.onCursorImage = { [weak self] image in
            DispatchQueue.main.async { self?.renderer?.setCursorImage(image) }
        }
        receiver.onCursorPosition = { [weak self] position in
            DispatchQueue.main.async { self?.renderer?.setCursorPosition(position) }
        }
        renderer?.onEmergencyDismiss = { [weak receiver] in receiver?.dropConnections() }
        receiver.onFrame = { [weak self, headless] config, session, frame, decoded in
            let sample = readings.update { $0.record(config, address: session.remoteAddress, frame: frame, decoded: decoded) }
            if sample {
                meter.sample(decoded.surface) { proof in
                    readings.update { state in state.pendingSamples -= 1; state.chroma.append(proof) }
                }
            }
            if !headless {
                DispatchQueue.main.async {
                    guard let self, let renderer = self.renderer else { return }
                    let start = DispatchTime.now().uptimeNanoseconds
                    if renderer.present(decoded.surface, colorSpace: config.colorSpace) {
                        self.presentationTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                        self.presentationName = renderer.activePresentationPath.rawValue
                        if self.verifyPresentation, self.presentationTimes.count == 8,
                           let window = renderer.presentationWindow {
                            if self.verifyScanout {
                                self.presentingMode = ScanoutProof.Mode.read(windowBacking: window.backingSize)
                            }
                            self.proofTask = Task { [weak self] in
                                self?.presentationProof = await WindowPresentationProof.capture(window: UInt32(window.number), backingSize: window.backingSize)
                            }
                        }
                    }
                }
            }
        }
        defer {
            receiver.dropConnections()
            renderer?.dismiss()
            listener.stop()
        }
        try listener.start(port: port)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(duration)
        while clock.now < deadline && !readings.snapshot().ended { try await Task.sleep(for: .milliseconds(25)) }
        let samplesDeadline = clock.now + .seconds(2)
        while readings.snapshot().pendingSamples > 0 && clock.now < samplesDeadline { try await Task.sleep(for: .milliseconds(10)) }
        await proofTask?.value
        listener.stop()
        receiver.dropConnections()
        renderer?.dismiss()
        var scanoutProof: ScanoutProof?
        if verifyScanout {
            let restoreDeadline = clock.now + .seconds(1)
            while ScanoutProof.Mode.read() != originalMode && clock.now < restoreDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            scanoutProof = ScanoutProof(before: originalMode, during: presentingMode, after: ScanoutProof.Mode.read())
        }
        let state = readings.snapshot()
        let interval = state.start.flatMap { first in state.last.map { Double($0 - first) / 1e9 } } ?? 0
        try printJSON(Summary(
            output: output, profile: state.config?.profile,
            pixels: state.config.map { "\($0.width)×\($0.height)" },
            presentedFrames: presentationTimes.count, presentationMs: Percentiles(presentationTimes),
            presentationPath: presentationName, presentationProof: presentationProof, releasedWindow: !hasVisibleWindow(),
            scanoutProof: scanoutProof,
            linkKind: state.config?.linkKind, remoteAddress: state.address, advertised: advertised,
            submittedToDecoder: receiver.submittedFrames, decodedFrames: state.decode.count,
            sustainedFPS: interval > 0 ? Double(state.decode.count - 1) / interval : 0,
            decodeMs: Percentiles(state.decode),
            megabitsPerSecond: interval > 0 ? Double(state.bytes) * 8e-6 / interval : 0,
            hvcC: state.format, chroma: state.chroma, errors: state.errors
        ))
        guard !verifyScanout || scanoutProof?.passed == true,
              !verifyPresentation || presentationProof?.passed == true,
              !state.decode.isEmpty, headless || !presentationTimes.isEmpty,
              !state.chroma.isEmpty, state.chroma.allSatisfy(\.passed), state.errors.isEmpty else {
            throw RetinaLinkError.operation("Receiver benchmark failed pixel, chroma, or decoder verification")
        }
    }

    private func hasVisibleWindow() -> Bool { NSApplication.shared.windows.contains(where: \.isVisible) }
}

private struct ReceiverReadings {
    var decode = [Double]()
    var chroma = [ChromaProof]()
    var errors = [String]()
    var bytes = 0
    var pendingSamples = 0
    var config: SenderConfig?
    var address: String?
    var format: String?
    var start: UInt64?
    var last: UInt64?
    var ended = false

    mutating func record(_ config: SenderConfig, address: String?, frame: ReceivedFrame,
                         decoded: DecodedVideoFrame) -> Bool {
        self.config = config
        self.address = address
        switch frame {
        case .hevc(let frame):
            if format == nil, let info = try? HEVCFormat(hvcC: frame.hvcC) {
                format = "\(info.profileIDC)/\(info.chromaFormat)/\(info.bitDepthLuma)"
            }
            bytes += frame.nalUnits.count + frame.hvcC.count + 28
        case .lossless(let frame):
            bytes += frame.payloadBytes
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if start == nil { start = now }
        last = now
        decode.append(Double(decoded.decodeUs) / 1000)
        guard (decode.count == 2 || decode.count.isMultiple(of: 60)), pendingSamples < 2 else { return false }
        pendingSamples += 1
        return true
    }
}

final class LockedReadings<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func update<T>(_ update: (inout Value) -> T) -> T { lock.withLock { update(&value) } }
    func snapshot() -> Value { lock.withLock { value } }
}

private struct SenderReadings {
    var failure: String?
    var frames = [FrameMeasurement]()
    var rtt = [Double]()
}

@MainActor
final class SenderBench {
    struct Summary: Codable {
        let profile: HEVCProfile
        let pixels: String
        let requestedFPS: Int
        let sourceChromaVerified: Bool
        let sustainedFPS: Double
        let metTargetFPS: Bool
        let submitted: Int
        let encoded: Int
        let acknowledged: Int
        let droppedFrames: Int
        let peakInFlight: Int
        let encodeMs: Percentiles
        let decodeMs: Percentiles
        let rttMs: Percentiles
        let captureToAckMs: Percentiles
        let megabitsPerSecond: Double
        let selected: EndpointCandidate
        let effectiveLinkKind: LinkKind
        let candidates: [EndpointCandidate]
        let screenRecordingPermission: Bool
    }

    private let args: Arguments
    private let duration: Double
    private let profile: HEVCProfile

    init(_ args: Arguments) throws {
        self.args = args
        duration = try args.duration()
        guard let profile = HEVCProfile(rawValue: args.values["--profile"] ?? "hevc444_10") else {
            throw Arguments.usage
        }
        self.profile = profile
    }

    func run() async throws {
        let (route, probed) = try await route()
        let frames = try TestPattern.makeFrames()
        let meter = ChromaMeter()
        let sourceProof = await withCheckedContinuation { continuation in
            meter.sample(frames[0]) { continuation.resume(returning: $0) }
        }
        guard sourceProof.colorExact else {
            throw RetinaLinkError.operation("Synthetic Display P3 source does not match the input reference")
        }
        let (session, hello) = try await SenderHandshake.open(candidate: route)
        let selected = args.values["--host"] != nil
            ? EndpointCandidate(kind: hello.ingressKind ?? route.kind, host: route.host, port: route.port, rttMs: route.rttMs)
            : route
        let candidates = args.values["--host"] != nil ? [selected] : probed
        defer { session.close() }
        guard hello.panelPixelWidth == TestPattern.width, hello.panelPixelHeight == TestPattern.height else {
            throw RetinaLinkError.operation("Benchmark receiver did not report a 4480×2520 panel")
        }
        let effectiveKind = session.effectiveLinkKind(receiverIngress: hello.ingressKind ?? selected.kind)
        let config = SenderConfig(name: "RetinaLink Synthetic Benchmark", width: UInt16(TestPattern.width),
                                  height: UInt16(TestPattern.height), profile: profile, colorSpace: .displayP3,
                                  linkKind: effectiveKind, cursorMode: .overlay)
        let sender = try FrameSender(config: config)
        defer { sender.stop() }
        let metrics = LockedReadings(SenderReadings())
        session.onRTT = { value in metrics.update { $0.rtt.append(value) } }
        sender.onMeasurement = { value in
            if value.decodeUs > 0 { metrics.update { $0.frames.append(value) } }
        }
        sender.onError = { error in metrics.update { $0.failure = error.localizedDescription } }
        sender.onLinkLost = { reason in metrics.update { $0.failure = reason } }
        session.send(.senderConfig(config))
        sender.attach(session, kind: selected.kind)
        let clock = ContinuousClock()
        let start = clock.now + .milliseconds(1)
        let ticks = Int((duration * 60).rounded())
        let end = start + .seconds(duration)
        for tick in 0..<ticks {
            try await clock.sleep(until: start + .nanoseconds(Int64(tick) * 1_000_000_000 / 60),
                                  tolerance: .microseconds(150))
            if metrics.snapshot().failure != nil || clock.now >= end { break }
            sender.submit(frames[(tick / 3) % frames.count], captureTimeNs: DispatchTime.now().uptimeNanoseconds)
        }
        if clock.now < end { try await clock.sleep(until: end) }
        let drain = clock.now + .seconds(2)
        while sender.inFlight > 0 && clock.now < drain && metrics.snapshot().failure == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let result = metrics.snapshot()
        let readings = result.frames
        let rtt = result.rtt
        let permission = ScreenCapturePipeline.hasScreenRecordingPermission()
        try printJSON(Summary(
            profile: profile, pixels: "\(config.width)×\(config.height)", requestedFPS: 60,
            sourceChromaVerified: sourceProof.colorExact, sustainedFPS: Double(readings.count) / duration,
            metTargetFPS: readings.count == ticks, submitted: sender.submittedFrames,
            encoded: sender.encodedFrames, acknowledged: readings.count, droppedFrames: ticks - readings.count, peakInFlight: sender.peakInFlight,
            encodeMs: Percentiles(readings.map { Double($0.encodeUs) / 1000 }),
            decodeMs: Percentiles(readings.map { Double($0.decodeUs) / 1000 }), rttMs: Percentiles(rtt),
            captureToAckMs: Percentiles(readings.map(\.deliveryMs)),
            megabitsPerSecond: Double(readings.reduce(0) { $0 + Int($1.receivedBytes) }) * 8e-6 / duration,
            selected: selected, effectiveLinkKind: effectiveKind, candidates: candidates, screenRecordingPermission: permission
        ))
        session.onClose = nil
        session.disconnect(reason: "Benchmark complete")
        try await Task.sleep(for: .milliseconds(50))
        if let failure = result.failure { throw RetinaLinkError.operation(failure) }
        guard !readings.isEmpty else { throw RetinaLinkError.operation("No frames were acknowledged") }
    }

    private func route() async throws -> (EndpointCandidate, [EndpointCandidate]) {
        if let host = args.values["--host"] {
            let candidate = EndpointCandidate(kind: .wifi, host: host, port: try args.port(default: 58420))
            let reachable = await LinkDiscovery.probe([candidate])
            guard let selected = reachable.first else { throw RetinaLinkError.operation("Receiver unreachable at \(host)") }
            return (selected, reachable)
        }
        guard args.flags.contains("--discover") else { throw Arguments.usage }
        let discovery = LinkDiscovery()
        defer { discovery.stop() }
        discovery.start()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        while clock.now < deadline {
            if let peer = discovery.peers.first(where: { $0.name.hasPrefix("RetinaLink Bench") && !$0.candidates.isEmpty }) {
                let reachable = await LinkDiscovery.probe(peer.candidates)
                if let selected = reachable.first { return (selected, reachable) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RetinaLinkError.operation("No reachable RetinaLink benchmark receiver was discovered")
    }
}
