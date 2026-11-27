import AppKit
import CoreVideo
import CryptoKit
import RetinaLinkEngine

@MainActor
enum LosslessProof {
    static let width = 4480
    static let height = 2520
    static let crop = CGRect(x: 12, y: 1960, width: 1024, height: 256)
    static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    nonisolated private static let name = "RetinaLink Typography Proof"

    static func fixture(_ args: Arguments) throws {
        guard let output = args.values["--output"] else { throw Arguments.usage }
        let (full, patch) = try surfaces()
        let hashes = digest(full) + digest(patch)
        try hashes.write(to: URL(fileURLWithPath: output))
        print("Reference SHA-256 for both complete 4480×2520 BGRA images written to \(output)")
    }

    static func send(_ args: Arguments) async throws {
        guard let host = args.values["--host"] else { throw Arguments.usage }
        let (baseline, update) = try surfaces()
        let candidate = EndpointCandidate(kind: .thunderbolt, host: host, port: try args.port(default: 58430))
        let (session, hello) = try await SenderHandshake.open(candidate: candidate)
        defer { session.close() }
        guard hello.supportsProgressiveLossless, hello.panelPixelWidth == width, hello.panelPixelHeight == height else {
            throw RetinaLinkError.operation("Expected the isolated typography proof receiver")
        }
        let ingress = hello.ingressKind ?? candidate.kind
        let kind = session.effectiveLinkKind(receiverIngress: ingress)
        let config = SenderConfig(name: name, width: UInt16(width), height: UInt16(height),
                                  profile: .hevc444_10, colorSpace: .displayP3, linkKind: kind, cursorMode: .overlay)
        let sender = try FrameSender(config: config, linkSpeedMbps: session.localLinkSpeedMbps)
        defer { sender.stop() }
        let measurements = LockedReadings<[FrameMeasurement]>([])
        let failure = LockedReadings<String?>(nil)
        sender.onMeasurement = { sample in measurements.update { $0.append(sample) } }
        sender.onError = { error in failure.update { $0 = error.localizedDescription } }
        session.send(.senderConfig(config))
        sender.attach(session, kind: ingress, receiverSupportsLossless: true)
        let clock = ContinuousClock()
        let start = clock.now
        sender.submit(baseline, captureTimeNs: DispatchTime.now().uptimeNanoseconds)
        try await wait("full settle ACK", failure: failure) { sender.isLosslessSettled }
        let first = measurements.snapshot()
        sender.submit(update, captureTimeNs: DispatchTime.now().uptimeNanoseconds)
        try await wait("cached settle ACK", failure: failure) {
            sender.isLosslessSettled && measurements.snapshot().count >= first.count + 2
        }
        let second = measurements.snapshot()
        sender.submit(baseline, captureTimeNs: DispatchTime.now().uptimeNanoseconds, dirtyRects: [crop])
        try await wait("typing patch ACK", failure: failure) {
            sender.isLosslessSettled && measurements.snapshot().count > second.count
        }
        let samples = measurements.snapshot()
        guard samples.allSatisfy({ $0.decodeUs > 0 }), sender.encodedFrames == 2 else {
            throw RetinaLinkError.operation("Expected two HEVC frames and successful lossless ACKs")
        }
        print("Peer \(host):\(candidate.port), \(kind.displayName), local link speed \(sender.linkSpeedMbps.map(String.init) ?? "unknown") Mbps")
        for (label, phase) in [("Initial", Array(first.dropFirst())),
                               ("Cached", Array(second.dropFirst(first.count + 1))),
                               ("Typing", Array(samples.dropFirst(second.count)))] {
            print("\(label): chunks=\(phase.count) encodeUs=\(phase.first?.encodeUs ?? 0) decodeTotalUs=\(phase.reduce(0) { $0 + Int($1.decodeUs) }) wireBytes=\(phase.reduce(0) { $0 + Int($1.receivedBytes) + WireFrame.headerSize }) captureToAckMs=\(phase.last?.deliveryMs ?? 0)")
        }
        try await clock.sleep(until: start + .seconds(3))
    }

    static func receive(_ args: Arguments) async throws {
        guard args.flags.contains("--headless"), let file = args.values["--output"] else { throw Arguments.usage }
        let references = try Data(contentsOf: URL(fileURLWithPath: file))
        guard references.count == 64 else { throw RetinaLinkError.operation("Invalid typography reference hashes") }
        let hello = ReceiverHello(name: name, panelPixelWidth: width, panelPixelHeight: height, cursorPort: nil,
                                  losslessVersion: LosslessFrame.protocolVersion, supportedProfiles: HEVCDecoder.supportedHardwareProfiles())
        let receiver = FrameReceiver(hello: hello) { config, _ in config.name == name }
        let listener = LinkListener(name: name, width: width, height: height)
        defer { listener.stop(); receiver.dropConnections() }
        let received = LockedReadings<[(ReceivedFrame, DecodedVideoFrame)]>([])
        let failure = LockedReadings<String?>(nil)
        listener.onSession = { session, port, addresses in receiver.accept(session, cursorPort: port, addresses: addresses) }
        listener.onError = { error in failure.update { $0 = error } }
        listener.onListening = { port, _ in
            FileHandle.standardError.write(Data("LISTENING \(port)\n".utf8))
        }
        receiver.onError = { error in failure.update { $0 = error } }
        receiver.onFrame = { _, _, frame, decoded in received.update { $0.append((frame, decoded)) } }
        try listener.start(port: args.port(default: 58430))
        try await wait("HEVC → settle → HEVC → cached settle → dirty patch", seconds: 30, failure: failure) {
            received.snapshot().count >= 5
        }
        let frames = received.snapshot()
        guard case .hevc = frames[0].0, case .lossless(let settle) = frames[1].0,
              case .hevc = frames[2].0, case .lossless(let cached) = frames[3].0,
              case .lossless(let patch) = frames[4].0,
              settle.present, cached.present, patch.present, !cached.resetsStaging, !patch.resetsStaging,
              patch.baseFrameID == cached.frameID, patch.patches.allSatisfy({ $0.algorithm == .lz4 }),
              patch.patches.map(\.rect) == DirtyRects([crop], width: width, height: height).rects else {
            throw RetinaLinkError.operation("Unexpected typography proof frame sequence")
        }
        let renderer = DisplayRendererView()
        renderer.frame = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
        for (frame, decoded) in frames.prefix(5) {
            let buffer = decoded.surface.pixelBuffer
            guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
                  CVPixelBufferGetIOSurface(buffer) != nil else {
                throw RetinaLinkError.operation("Missing 4480×2520 IOSurface")
            }
            guard renderer.presentInView(decoded.surface, colorSpace: .displayP3),
                  renderer.activePresentationPath == .direct, renderer.displaysDirectly(decoded.surface),
                  renderer.presentationWindow == nil else {
                throw RetinaLinkError.operation("Offscreen renderer did not retain the IOSurface directly")
            }
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let fourCC = String(bytes: (0..<4).reversed().map { UInt8(truncatingIfNeeded: format >> ($0 * 8)) }, encoding: .ascii)
            print("frame=\(frame.frameID) IOSurface=\(fourCC ?? "?") decodeUs=\(decoded.decodeUs)")
        }
        for (index, frame, reference) in [(1, settle, 0), (3, cached, 1), (4, patch, 0)] {
            let decoded = frames[index].1
            let buffer = decoded.surface.pixelBuffer
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  let taggedColorSpace = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil),
                  CFEqual(taggedColorSpace, p3),
                  digest(decoded.surface) == references.subdata(in: (reference * 32)..<((reference + 1) * 32)) else {
                throw RetinaLinkError.operation("Full desktop pixel digest mismatch for frame \(frame.frameID)")
            }
            let bytes = frame.patches.reduce(0) { $0 + $1.compressedBytes.count }
            print("frame=\(frame.frameID) patches=\(frame.patches.count) finalChunkCompressedBytes=\(bytes) maxRGBError=0/255 exactBGRA=100.00%")
        }
    }

    private static func wait(_ what: String, seconds: Double = 5, failure: LockedReadings<String?>,
                             until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if let reason = failure.snapshot() { throw RetinaLinkError.operation(reason) }
            guard ContinuousClock.now < deadline else { throw RetinaLinkError.operation("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func surfaces() throws -> (VideoSurface, VideoSurface) {
        let fonts = [NSFont.systemFont(ofSize: 11), NSFont.systemFont(ofSize: 13),
                     NSFont(name: "Menlo-Regular", size: 11)!, NSFont(name: "Menlo-Regular", size: 13)!]
        print("Fonts: " + fonts.map { "\($0.fontName) \($0.pointSize)pt" }.joined(separator: ", "))
        let baseline = try render(fonts: fonts, alternate: false)
        let alternate = try render(fonts: fonts, alternate: true)
        guard digest(baseline) != digest(alternate) else {
            throw RetinaLinkError.operation("Typing fixture did not change the source image")
        }
        return (baseline, alternate)
    }

    private static func digest(_ surface: VideoSurface) -> Data {
        Data(SHA256.hash(data: raw(surface)))
    }

    @MainActor static func render(fonts: [NSFont], alternate: Bool) throws -> VideoSurface {
        let surface = try buffer()
        let pixel = surface.pixelBuffer
        guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else {
            throw RetinaLinkError.operation("Could not lock the typography surface")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: p3,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw RetinaLinkError.operation("Cannot make typography CGContext")
        }
        cg.scaleBy(x: 2, y: 2)
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let lines = [
            "let frame = display.capture(at: .native)",
            "The quick brown fox jumps over the lazy dog.",
            "Il1|  mnwm  S8B  rn  0123456789",
            "Typography at two pixels per point",
            "guard let surface else { return }",
            "let packet = try writer.append(sample)",
            "Display P3 • Apple Silicon • 60 Hz",
            "$ swift test -q  # All checks passed",
            "A small detail makes the type easier to read.",
            "RetinaLink / WindowServer / Frame 2048",
            "for value in frames { present(value) }",
            "private var pending: [Frame] = []",
        ]
        let panelW = width / 8
        let panelH = height / 4
        for row in 0..<2 {
            for column in 0..<4 {
                let x = column * panelW
                let y = row * panelH
                let dark = row == 0
                let background = CGFloat(dark ? 20 : 249) / 255
                let foreground = CGFloat(dark ? 246 : 22) / 255
                let bg = CGColor(colorSpace: p3, components: [background, background, background, 1])!
                let fg = NSColor(displayP3Red: foreground, green: foreground, blue: foreground, alpha: 1)
                cg.setFillColor(bg)
                cg.fill(CGRect(x: x, y: y, width: panelW, height: panelH))
                let font = fonts[column]
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
                let fromTop = panelH - 30
                let step = Int(font.pointSize) + 6
                for line in 0..<(fromTop / step) {
                    let content = alternate && row == 0 && column == 0 && (21...24).contains(line)
                        ? "git status --short  |  main  \(line)" : lines[(line + column) % lines.count]
                    let text = String(format: "%02d  ", line + 1) + content
                    NSAttributedString(string: text, attributes: attrs).draw(
                        at: CGPoint(x: x + 18, y: y + fromTop - line * step))
                }
            }
        }
        return surface
    }

    static func buffer() throws -> VideoSurface {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw RetinaLinkError.videoToolbox("Typography input", status) }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, p3, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return VideoSurface(buffer)
    }

    static func raw(_ surface: VideoSurface) -> Data {
        let buffer = surface.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var result = Data(capacity: width * height * 4)
        for row in 0..<height { result.append(base.advanced(by: row * stride), count: width * 4) }
        return result
    }

}
