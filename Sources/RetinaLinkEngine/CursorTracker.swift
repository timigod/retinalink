import AppKit
import CoreGraphics
import CryptoKit
import RetinaLinkCore

@MainActor
final class CursorTracker {
    private var timer: (any DispatchSourceTimer)?
    private var sequence: UInt32 = 0
    private var lastPosition: CursorPosition?
    private var lastSource: (image: CGImage, hotSpot: CGPoint, size: CGSize)?
    private var rasterizedImage: (source: NSImage, output: CGImage)?
    private var currentImage: CursorImage?

    func start(displayID: CGDirectDisplayID, onImage: @escaping (CursorImage) -> Void,
               onPosition: @escaping (CursorPosition) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.sample(displayID: displayID, onImage: onImage, onPosition: onPosition)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastPosition = nil
        lastSource = nil
        currentImage = nil
        rasterizedImage = nil
    }

    private func sample(displayID: CGDirectDisplayID, onImage: (CursorImage) -> Void,
                        onPosition: (CursorPosition) -> Void) {
        guard CGDisplayIsOnline(displayID) != 0 else { stop(); return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: CGDisplayBounds(CGMainDisplayID()).height - location.y)
        let visible = bounds.contains(point)
        if visible { sampleImage(onImage: onImage) }
        let position = CursorPosition(
            sequence: sequence, cursorHash: currentImage?.cursorHash ?? 0,
            normX: Float((point.x - bounds.minX) / bounds.width),
            normY: Float((point.y - bounds.minY) / bounds.height), visible: visible
        )
        if let lastPosition, lastPosition.visible == position.visible {
            if !visible { return }
            if lastPosition.cursorHash == position.cursorHash, lastPosition.normX == position.normX,
               lastPosition.normY == position.normY { return }
        }
        lastPosition = position
        sequence &+= 1
        onPosition(position)
    }

    private func rasterizeAt2x(_ image: NSImage) -> CGImage? {
        if let cached = rasterizedImage, cached.source === image { return cached.output }
        let width = Int((image.size.width * 2).rounded())
        let height = Int((image.size.height * 2).rounded())
        guard (1...1024).contains(width), (1...1024).contains(height),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { return nil }
        rasterizedImage = (image, output)
        return output
    }

    private func sampleImage(onImage: (CursorImage) -> Void) {
        let cursor = NSCursor.currentSystem ?? .arrow
        let image = cursor.image
        // Request the largest representation, using AppKit's fallback for a
        // vector image. Do not PNG-encode the same shape on each timer tick.
        let best = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }
        guard let bitmap = ((best?.pixelsWide ?? 0) <= Int(image.size.width) ? rasterizeAt2x(image) : best?.cgImage)
                ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              bitmap.width <= 1024, bitmap.height <= 1024 else { return }
        if let previous = lastSource, previous.image === bitmap,
           previous.hotSpot == cursor.hotSpot, previous.size == image.size { return }
        guard let pixels = bitmap.dataProvider?.data as Data? else { return }
        lastSource = (bitmap, cursor.hotSpot, image.size)
        let scale = Float(CGFloat(bitmap.width) / max(image.size.width, 1))
        var hasher = SHA256()
        hasher.update(data: pixels)
        for field in [Float(bitmap.width), Float(bitmap.height), Float(cursor.hotSpot.x), Float(cursor.hotSpot.y), scale] {
            var value = field.bitPattern.bigEndian
            withUnsafeBytes(of: &value) { hasher.update(bufferPointer: $0) }
        }
        let hash = hasher.finalize().prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard currentImage?.cursorHash != hash,
              let png = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]) else { return }
        let payload = CursorImage(cursorHash: hash, width: UInt16(bitmap.width), height: UInt16(bitmap.height),
                                  hotSpotX: Float(cursor.hotSpot.x), hotSpotY: Float(cursor.hotSpot.y),
                                  scale: scale, pngBytes: png)
        currentImage = payload
        onImage(payload)
    }
}
