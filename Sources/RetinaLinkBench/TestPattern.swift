import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation
import RetinaLinkEngine

enum TestPattern {
    static let width = 4480
    static let height = 2520
    static let colors = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sampleWidth = 96
    static let sampleHeight = 32
    static let colorPatches: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [140, 100, 180]]

    static func colorPatchRect(at index: Int) -> CGRect {
        CGRect(x: 120 + index * 48, y: 8, width: 32, height: 32)
    }
    static let glyphs: [[UInt8]] = [
        [30, 17, 17, 30, 20, 18, 17], // R
        [14, 17, 16, 23, 17, 17, 14], // G
        [30, 17, 17, 30, 17, 17, 30], // B
    ]

    static func foreground(x: Int, y: Int, channel: Int) -> Bool {
        let column = x - channel * 32
        if (2..<19).contains(column), (2..<30).contains(y) {
            let glyph = glyphs[channel]
            return glyph[(y - 2) % 7] & (0x10 >> ((column - 2) % 6)) != 0
        }
        return (21..<30).contains(column) && (2..<30).contains(y) && (column % 2 == 1)
    }

    static func makeFrames() throws -> [VideoSurface] {
        try (0..<8).map { phase in
            try autoreleasepool { try makeFrame(phase: phase) }
        }
    }

    private static func makeFrame(phase: Int) throws -> VideoSurface {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw RetinaLinkError.videoToolbox("Test pattern buffer", status)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colors, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65,
                              .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB,
                              .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: colors, bitmapInfo: bitmap) else {
            throw RetinaLinkError.operation("Cannot draw the Display P3 test pattern")
        }
        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
            CGColor(colorSpace: colors, components: [red, green, blue, 1])!
        }
        context.setFillColor(color(0.069, 0.09, 0.12))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 16, nil)
        let gutter = color(0.40, 0.47, 0.57)
        let palette = [color(0.83, 0.89, 0.94), color(0.97, 0.45, 0.69), color(0.42, 0.80, 0.94),
                       color(0.68, 0.93, 0.57), color(0.99, 0.70, 0.49)]
        let statements = [
            ["struct ", "DisplayMode", " { let pixels: CGSize; let scale: Float }"],
            ["let ", "buffer", " = try pool.makeIOSurface(width: 4480, height: 2520)"],
            ["guard ", "let frame = reader.next()", " else { return nil }"],
            ["     ", "let conversion", " = matrix.apply(rgb, gamut: .displayP3)"],
            ["func ", "connect(to endpoint: Endpoint)", " async throws -> Session {"],
            ["     ", "return try await listener.accept(frame: incoming)", " // verified"],
            ["     ", "let rtt = Double(now - sent) / 1_000_000", " // milliseconds"],
            ["case ", ".frameAck(let ack)", ": queue.remove(ack.frameID)"],
            ["     ", "context.setFillColor(palette[index % palette.count])", ""],
            ["     ", "let descriptor = DisplayDescriptor(serial: 0x00010001)", ""],
        ]
        for pane in 0..<4 {
            let left = pane * (width / 4)
            context.setFillColor(color(0.12, 0.15, 0.19))
            context.fill(CGRect(x: left, y: 0, width: 62, height: height))
            context.fill(CGRect(x: left, y: height - 64, width: width / 4 - 4, height: 64))
            draw("RetinaLink / Sources / DisplayPipeline\(pane + 1).swift", at: CGPoint(x: left + 82, y: height - 41),
                 color: palette[0], font: font, context: context)
            let activeRow = 42 + phase + pane * 8
            context.setFillColor(color(0.15, 0.22, 0.30))
            context.fill(CGRect(x: left + 64, y: height - 89 - activeRow * 20, width: width / 4 - 70, height: 20))
            for row in 0..<120 {
                let line = row + 1 + pane * 120
                let y = height - 84 - row * 20
                draw(String(format: "%4d", line), at: CGPoint(x: left + 8, y: y),
                     color: gutter, font: font, context: context)
                var cursorX = CGFloat(left + 83)
                let variant = row > activeRow && row <= activeRow + 18 ? phase : 0
                for (index, text) in statements[(line + variant) % statements.count].enumerated() {
                    cursorX += draw(text, at: CGPoint(x: cursorX, y: CGFloat(y)),
                                    color: palette[(row + index) % palette.count], font: font, context: context)
                }
            }
        }
        context.setShouldAntialias(false)
        context.setFillColor(color(0, 0, 0))
        context.fill(CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        for channel in 0..<3 {
            context.setFillColor(color(channel == 0 ? 1 : 0, channel == 1 ? 1 : 0, channel == 2 ? 1 : 0))
            for y in 0..<sampleHeight {
                for x in (channel * 32)..<((channel + 1) * 32) where foreground(x: x, y: y, channel: channel) {
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        for (index, patch) in colorPatches.enumerated() {
            context.setFillColor(color(CGFloat(patch[0]) / 255, CGFloat(patch[1]) / 255,
                                       CGFloat(patch[2]) / 255))
            context.fill(colorPatchRect(at: index))
        }
        return VideoSurface(buffer)
    }

    @discardableResult
    private static func draw(_ text: String, at point: CGPoint, color: CGColor, font: CTFont,
                             context: CGContext) -> CGFloat {
        let value = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(value)
        context.textPosition = point
        CTLineDraw(line, context)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}

struct ChromaProof: Codable, Sendable {
    struct Channel: Codable, Sendable {
        let color: String
        let edgeContrast: Double
        let inputEdgeContrast: Double
        let meanAbsoluteError: Double
        let worstAbsoluteError: Int
        let exactComponentsPercent: Double
    }

    let channels: [Channel]
    let pixelFormat: String
    let iosurfaceBacked: Bool
    let displayP3Tagged: Bool
    let passed: Bool
    let colorExact: Bool
}

final class ChromaMeter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RetinaLink.bench.chroma", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])

    func sample(_ surface: VideoSurface, report: @escaping @Sendable (ChromaProof) -> Void) {
        queue.async { [self] in
            let buffer = surface.pixelBuffer
            let width = TestPattern.sampleWidth
            let height = TestPattern.sampleHeight
            let crop = CGRect(x: 0, y: 0, width: width, height: height)
            let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: TestPattern.colors]).cropped(to: crop)
            var rgb = [UInt8](repeating: 0, count: width * height * 4)
            rgb.withUnsafeMutableBytes { bytes in
                context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 4, bounds: crop,
                               format: .RGBA8, colorSpace: TestPattern.colors)
            }
            // Core Image's bitmap memory can be top-row-first for a CV source.
            // Resolve orientation against the reference using its asymmetric glyphs.
            let direct = Self.measure(rgb, flipped: false)
            let flipped = Self.measure(rgb, flipped: true)
            let channels = direct.map(\.meanAbsoluteError).reduce(0, +)
                <= flipped.map(\.meanAbsoluteError).reduce(0, +) ? direct : flipped
            let type = CVPixelBufferGetPixelFormatType(buffer)
            let fourCC = String(bytes: (0..<4).reversed().map { UInt8(truncatingIfNeeded: type >> ($0 * 8)) },
                                encoding: .ascii) ?? String(type)
            let tag = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
            let tagged = tag == (kCVImageBufferColorPrimaries_P3_D65 as String)
            let ioSurface = CVPixelBufferGetIOSurface(buffer) != nil
            report(ChromaProof(
                channels: channels, pixelFormat: fourCC, iosurfaceBacked: ioSurface, displayP3Tagged: tagged,
                passed: ioSurface && tagged && channels.allSatisfy { $0.edgeContrast > 0.98 && $0.meanAbsoluteError <= 24 },
                colorExact: tagged && channels.allSatisfy { $0.worstAbsoluteError == 0 }
            ))
        }
    }

    private static func measure(_ bytes: [UInt8], flipped: Bool) -> [ChromaProof.Channel] {
        let width = TestPattern.sampleWidth
        let height = TestPattern.sampleHeight
        func sample(_ x: Int, _ y: Int, _ channel: Int) -> Int {
            let row = flipped ? height - 1 - y : y
            return Int(bytes[(row * width + x) * 4 + channel])
        }
        return ["red", "green", "blue"].enumerated().map { channel, label in
            let offset = channel * 32
            var difference = 0
            var errors = 0
            var worst = 0
            var exact = 0
            var count = 0
            for y in 2..<30 {
                for x in 2..<30 {
                    let ink = TestPattern.foreground(x: offset + x, y: y, channel: channel)
                    for component in 0..<3 {
                        let expected = component == channel && ink ? 255 : 0
                        let error = abs(sample(offset + x, y, component) - expected)
                        errors += error
                        worst = max(worst, error)
                        exact += error == 0 ? 1 : 0
                        count += 1
                    }
                }
                for x in stride(from: 21, through: 27, by: 2) {
                    difference += sample(offset + x, y, channel) - sample(offset + x + 1, y, channel)
                }
            }
            return ChromaProof.Channel(
                color: label, edgeContrast: Double(difference) / Double(28 * 4 * 255), inputEdgeContrast: 1,
                meanAbsoluteError: Double(errors) / Double(count), worstAbsoluteError: worst,
                exactComponentsPercent: Double(exact) * 100 / Double(count)
            )
        }
    }
}
