import AppKit
import CoreMedia
import CoreVideo
import RetinaLinkCore
@preconcurrency import ScreenCaptureKit

// Core Video retains the surface. Producers hand off completed buffers and
// consumers treat them as immutable.
public struct VideoSurface: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

@MainActor
public final class ScreenCapturePipeline {
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var generation = 0

    public init() {}

    public static func hasScreenRecordingPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func start(
        displayID: CGDirectDisplayID, width: Int, height: Int, cursorMode: CursorMode,
        onFrame: @escaping @Sendable (VideoSurface, UInt64, [CGRect]) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws {
        await stop()
        generation += 1
        let startingGeneration = generation
        var display: SCDisplay?
        for _ in 0..<10 {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            display = shareable.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard generation == startingGeneration else { throw CancellationError() }
        guard let display else { throw RetinaLinkError.operation("ScreenCaptureKit cannot see the virtual display") }

        let configuration = SCStreamConfiguration()
        configuration.captureResolution = .best
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.showsCursor = cursorMode == .embedded
        let output = CaptureOutput(onFrame: onFrame, onError: onError)
        let capture = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration, delegate: output
        )
        try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        stream = capture
        self.output = output
        do {
            try await capture.startCapture()
        } catch {
            if generation == startingGeneration { await stop() }
            throw error
        }
        if generation != startingGeneration {
            try? await capture.stopCapture()
            throw CancellationError()
        }
    }

    public func stop() async {
        generation += 1
        let capture = stream
        let output = self.output
        stream = nil
        self.output = nil
        if let capture, let output {
            try? capture.removeStreamOutput(output, type: .screen)
            try? await capture.stopCapture()
        }
    }
}

private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "RetinaLink.capture", qos: .userInteractive)
    let onFrame: @Sendable (VideoSurface, UInt64, [CGRect]) -> Void
    let onError: @Sendable (Error) -> Void

    init(onFrame: @escaping @Sendable (VideoSurface, UInt64, [CGRect]) -> Void,
         onError: @escaping @Sendable (Error) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]],
              let fields = attachments.first,
              let status = fields[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sample.imageBuffer else { return }
        onFrame(VideoSurface(pixelBuffer), DispatchTime.now().uptimeNanoseconds,
                Self.dirtyRects(fields, buffer: pixelBuffer))
    }

    private static func dirtyRects(_ fields: [SCStreamFrameInfo: Any], buffer: CVPixelBuffer) -> [CGRect] {
        guard let values = fields[.dirtyRects] as? [Any],
              let content = rect(fields[.contentRect]),
              let contentScale = fields[.contentScale] as? CGFloat,
              let scaleFactor = fields[.scaleFactor] as? CGFloat else { return [] }
        let rects = values.compactMap { rect($0) }
        guard rects.count == values.count else { return [] }
        return CaptureDirtyRects.normalize(rects, contentRect: content, contentScale: contentScale, scaleFactor: scaleFactor,
                                          width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }

    private static func rect(_ value: Any?) -> CGRect? {
        if let rect = value as? CGRect { return rect }
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
