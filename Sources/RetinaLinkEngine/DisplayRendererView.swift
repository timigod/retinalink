import AppKit
import AVFoundation
import CoreMedia
import CoreImage
import CoreVideo
import ImageIO
import IOKit.pwr_mgt
import Metal
import QuartzCore
import RetinaLinkCore

@MainActor
public final class DisplayRendererView: NSView {
    public enum PresentationPath: String, Sendable {
        case automatic, direct, sampleBuffer, metal, metalFloat
    }

    public private(set) var activePresentationPath: PresentationPath = .automatic
    private let presentation: PresentationPath
    public var presentationWindow: (number: Int, backingSize: CGSize)? {
        overlay.map { ($0.windowNumber, convertToBacking(bounds).size) }
    }
    public var onEmergencyDismiss: (() -> Void)?
    private let imageLayer = CALayer()
    private let cursorLayer = CALayer()
    private var overlay: OverlayWindow?
    private var displayedSurface: VideoSurface?
    private var scanout: DisplayScanout?
    var isPreparingScanout: Bool {
        overlay == nil && scanout?.logicalSize != nil && scanout?.waitingForAppKit == true
    }
    private var assertion = IOPMAssertionID(kIOPMNullAssertionID)
    private var cursorHidden = false
    private var escapeTimes: [TimeInterval] = []
    private var cursorImage: (payload: CursorImage, image: CGImage)?
    private var cursorPosition: CursorPosition?
    private var metal: MetalPresenter?
    private var samplePresenter: SampleBufferPresenter?

    public init(presentation: PresentationPath = .automatic) {
        self.presentation = presentation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        cursorLayer.isHidden = true
        cursorLayer.magnificationFilter = .linear
        cursorLayer.minificationFilter = .trilinear
        cursorLayer.zPosition = 1
        layer?.addSublayer(cursorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        imageLayer.frame = bounds
        samplePresenter?.layer.frame = bounds
        metal?.layout(in: bounds, scale: window?.backingScaleFactor ?? 1)
        updateCursor()
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        escapeTimes.removeAll { event.timestamp - $0 > 1.2 }
        escapeTimes.append(event.timestamp)
        if escapeTimes.count == 3 {
            dismiss()
            onEmergencyDismiss?()
        }
    }

    @discardableResult
    public func present(_ surface: VideoSurface, colorSpace: StreamColorSpace = .displayP3,
                        on displayID: CGDirectDisplayID = CGMainDisplayID()) -> Bool {
        let buffer = surface.pixelBuffer
        guard CVPixelBufferGetIOSurface(buffer) != nil,
              showWindow(on: displayID, targetPixels: (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)))
        else { return false }
        return presentInView(surface, colorSpace: colorSpace)
    }

    package func presentInView(_ surface: VideoSurface, colorSpace: StreamColorSpace) -> Bool {
        guard let ioSurface = CVPixelBufferGetIOSurface(surface.pixelBuffer)?.takeUnretainedValue() else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path: PresentationPath = switch presentation {
        case .automatic where colorSpace == .displayP3: .direct
        case .automatic: .sampleBuffer
        default: presentation
        }
        if path == .direct {
            removeSamplePresenter()
            removeMetalPresenter()
            imageLayer.contents = ioSurface
            displayedSurface = surface
            activePresentationPath = .direct
            return true
        }
        imageLayer.contents = nil
        displayedSurface = nil
        if path == .sampleBuffer {
            removeMetalPresenter()
            if samplePresenter == nil {
                let presenter = SampleBufferPresenter()
                presenter.layer.frame = bounds
                presenter.layer.contentsScale = window?.backingScaleFactor ?? 1
                layer?.insertSublayer(presenter.layer, above: imageLayer)
                samplePresenter = presenter
            }
            switch samplePresenter?.present(surface.pixelBuffer) {
            case .accepted:
                activePresentationPath = .sampleBuffer
                return true
            case .busy:
                return false
            default:
                if presentation != .automatic { return false }
            }
        }
        removeSamplePresenter()
        let metalPath: PresentationPath = path == .metalFloat ? .metalFloat : .metal
        if metal == nil, let presenter = MetalPresenter(useFloat: metalPath == .metalFloat) {
            metal = presenter
            layer?.insertSublayer(presenter.layer, above: imageLayer)
            presenter.layout(in: bounds, scale: window?.backingScaleFactor ?? 1)
        }
        guard metal?.present(surface.pixelBuffer, colors: colorSpace) == true else { return false }
        activePresentationPath = metalPath
        return true
    }

    package func displaysDirectly(_ surface: VideoSurface) -> Bool {
        guard let contents = imageLayer.contents,
              let ioSurface = CVPixelBufferGetIOSurface(surface.pixelBuffer)?.takeUnretainedValue() else { return false }
        return (contents as AnyObject) === ioSurface
    }

    private func removeSamplePresenter() {
        samplePresenter?.layer.sampleBufferRenderer.flush()
        samplePresenter?.layer.removeFromSuperlayer()
        samplePresenter = nil
    }

    private func removeMetalPresenter() {
        metal?.layer.removeFromSuperlayer()
        metal = nil
    }

    public func setCursorImage(_ payload: CursorImage) {
        guard let source = CGImageSourceCreateWithData(payload.pngBytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == Int(payload.width),
              properties[kCGImagePropertyPixelHeight] as? Int == Int(payload.height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        cursorImage = (payload, image)
        updateCursor()
    }

    public func setCursorPosition(_ position: CursorPosition) {
        if let old = cursorPosition {
            let delta = position.sequence &- old.sequence
            guard delta > 0, delta < 0x8000_0000 else { return }
        }
        cursorPosition = position
        updateCursor()
    }

    public func resetCursor() {
        cursorImage = nil
        cursorPosition = nil
        cursorLayer.contents = nil
        cursorLayer.isHidden = true
    }

    public func dismiss() {
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay?.close()
        overlay = nil
        scanout?.restore()
        scanout = nil
        imageLayer.contents = nil
        displayedSurface = nil
        removeSamplePresenter()
        removeMetalPresenter()
        activePresentationPath = .automatic
        resetCursor()
        escapeTimes.removeAll()
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        if assertion != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    private func showWindow(on displayID: CGDirectDisplayID, targetPixels: (width: Int, height: Int)) -> Bool {
        if let scanout, scanout.displayID != displayID { dismiss() }
        if overlay != nil { return true }
        let displayKey = NSDeviceDescriptionKey("NSScreenNumber")
        if scanout == nil {
            guard CGDisplayIsOnline(displayID) != 0 else { return false }
            scanout = DisplayScanout(displayID: displayID, targetWidth: targetPixels.width,
                                     targetHeight: targetPixels.height)
        }
        guard let scanout, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[displayKey] as? NSNumber)?.uint32Value == scanout.displayID
        }) else { return false }

        var frame = screen.frame
        var scale = screen.backingScaleFactor
        if let logicalSize = scanout.logicalSize, frame.size != logicalSize || scale != scanout.scale {
            // CoreGraphics applies synchronously. AppKit receives the new
            // geometry on a subsequent run-loop turn; retry on the next frame.
            if scanout.waitingForAppKit { return false }
            frame.size = CGDisplayBounds(scanout.displayID).size
            if let mode = CGDisplayCopyDisplayMode(scanout.displayID), mode.width > 0 {
                scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
            }
        }
        let app = NSApplication.shared
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered,
                                   defer: false, screen: screen)
        window.setFrame(frame, display: true)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = self
        overlay = window
        layer?.contentsScale = scale
        imageLayer.contentsScale = scale
        cursorLayer.contentsScale = scale
        app.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
        var userActivity = IOPMAssertionID(kIOPMNullAssertionID)
        if IOPMAssertionDeclareUserActivity("RetinaLink connected" as CFString, kIOPMUserActiveLocal, &userActivity)
            == kIOReturnSuccess {
            IOPMAssertionRelease(userActivity)
        }
        _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), "RetinaLink streaming" as CFString,
                                       &assertion)
        NSCursor.hide()
        cursorHidden = true
        return true
    }

    private func updateCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let cursorImage, let position = cursorPosition, position.visible, overlay != nil,
              cursorImage.payload.cursorHash == position.cursorHash else {
            cursorLayer.isHidden = true
            return
        }
        let payload = cursorImage.payload
        let scale = CGFloat(payload.scale)
        let width = CGFloat(payload.width) / scale
        let height = CGFloat(payload.height) / scale
        let backing = cursorLayer.contentsScale
        func snap(_ value: CGFloat) -> CGFloat { (value * backing).rounded() / backing }
        cursorLayer.frame = CGRect(
            x: snap(bounds.width * CGFloat(position.normX) - CGFloat(payload.hotSpotX)),
            y: snap(bounds.height * (1 - CGFloat(position.normY)) + CGFloat(payload.hotSpotY) - height),
            width: snap(width), height: snap(height)
        )
        cursorLayer.contents = cursorImage.image
        cursorLayer.isHidden = false
    }

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}

@MainActor
private final class MetalPresenter {
    let layer = CAMetalLayer()
    let context: CIContext
    let queue: MTLCommandQueue
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    init?(useFloat: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        layer.device = device
        layer.pixelFormat = useFloat ? .rgba16Float : .bgr10a2Unorm
        layer.colorspace = displayP3
        layer.framebufferOnly = false
        layer.allowsNextDrawableTimeout = true
    }

    func layout(in bounds: CGRect, scale: CGFloat) {
        layer.frame = bounds
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func present(_ buffer: CVPixelBuffer, colors: StreamColorSpace) -> Bool {
        guard let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else { return false }
        let space = switch colors {
        case .displayP3: CGColorSpace.displayP3
        case .sRGB: CGColorSpace.sRGB
        case .rec709: CGColorSpace.itur_709
        }
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: CGColorSpace(name: space)!])
        let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: bounds.width / image.extent.width,
                                                              y: bounds.height / image.extent.height))
        context.render(scaled, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: displayP3)
        command.present(drawable)
        command.commit()
        return true
    }
}


@MainActor
private final class SampleBufferPresenter {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() { layer.videoGravity = .resize }

    enum Result { case accepted, busy, failed }

    func present(_ buffer: CVPixelBuffer) -> Result {
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.status != .failed else { return .failed }
        guard renderer.isReadyForMoreMediaData else { return .busy }
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: buffer) {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                               formatDescriptionOut: &description) == noErr else {
                return .failed
            }
            format = description
        }
        guard let format else { return .failed }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            return .failed
        }
        let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        renderer.enqueue(sample)
        return .accepted
    }
}
