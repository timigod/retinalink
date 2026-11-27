import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

struct WindowPresentationProof: Codable, Sendable {
    let width: Int?
    let height: Int?
    let displayP3Patches: [[UInt8]]?
    let maximumComponentError: Int?
    let onePixelRGBContrast: [Double]?
    let passed: Bool
    let error: String?

    static func capture(window: CGWindowID, backingSize: CGSize) async -> Self {
        // Prefer ScreenCaptureKit when its scoped permission is available.
        // The older in-process function can read an app's own window on SDKs
        // where its Swift declaration has already been retired.
        do {
            if CGPreflightScreenCaptureAccess() {
                let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let ownWindow = available.windows.first(where: { $0.windowID == window &&
                    $0.owningApplication?.processID == getpid() }) else {
                    return failed("The app's presentation window was not available for capture")
                }
                let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
                let config = SCStreamConfiguration()
                config.captureResolution = .best
                config.width = Int(backingSize.width)
                config.height = Int(backingSize.height)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                return inspect(image, backingSize: backingSize)
            }
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let library = dlopen(nil, RTLD_LAZY) else { return failed("Window capture API is unavailable") }
            defer { dlclose(library) }
            guard let symbol = dlsym(library, "CGWindowListCreateImage") else {
                return failed("Window capture API is unavailable")
            }
            let capture = unsafeBitCast(symbol, to: Capture.self)
            guard let image = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, window,
                                      CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue() else {
                return failed("Window capture permission is unavailable")
            }
            return inspect(image, backingSize: backingSize)
        } catch {
            return failed(error.localizedDescription)
        }
    }

    private static func failed(_ reason: String) -> Self {
        Self(width: nil, height: nil, displayP3Patches: nil, maximumComponentError: nil, onePixelRGBContrast: nil, passed: false, error: reason)
    }

    private static func inspect(_ image: CGImage, backingSize: CGSize) -> Self {
        let width = image.width
        let height = image.height
        let left = max(0, (CGFloat(width) - backingSize.width) / 2)
        let top = max(0, (CGFloat(height) - backingSize.height) / 2)
        guard abs(CGFloat(width) - backingSize.width) <= 8,
              abs(CGFloat(height) - backingSize.height) <= 8 else {
            return Self(width: width, height: height, displayP3Patches: nil, maximumComponentError: nil,
                        onePixelRGBContrast: nil, passed: false, error: "Captured window does not match its backing size")
        }
        let patches: [[UInt8]] = TestPattern.colorPatches.indices.compactMap { index in
            let patch = TestPattern.colorPatchRect(at: index)
            let x = left + patch.midX / CGFloat(TestPattern.width) * backingSize.width
            let y = top + (1 - patch.midY / CGFloat(TestPattern.height)) * backingSize.height
            guard let crop = image.cropping(to: CGRect(x: Int(x) - 2, y: Int(y) - 2, width: 4, height: 4)) else {
                return nil
            }
            var rgb = [UInt8](repeating: 0, count: 4)
            return rgb.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: TestPattern.colors,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.interpolationQuality = .medium
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return Array(buffer.prefix(3))
            }
        }
        let maximumError = zip(patches, TestPattern.colorPatches).flatMap { actual, expected in
            zip(actual, expected).map { abs(Int($0) - Int($1)) }
        }.max()
        let edges = backingSize == CGSize(width: TestPattern.width, height: TestPattern.height)
            ? onePixelEdges(image, left: Int(left), top: Int(top)) : nil
        return Self(width: width, height: height, displayP3Patches: patches, maximumComponentError: maximumError,
                    onePixelRGBContrast: edges,
                    passed: patches.count == TestPattern.colorPatches.count && (maximumError ?? 255) <= 5, error: nil)
    }

    private static func onePixelEdges(_ image: CGImage, left: Int, top: Int) -> [Double]? {
        let width = TestPattern.sampleWidth
        let height = TestPattern.sampleHeight
        let rect = CGRect(x: left, y: top + TestPattern.height - height, width: width, height: height)
        guard let crop = image.cropping(to: rect) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        return rgba.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(data: pixels.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: TestPattern.colors,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return (0..<3).map { channel in
                var contrast = 0
                for y in 2..<30 {
                    for x in stride(from: 21, through: 27, by: 2) {
                        let pixel = (y * width + channel * 32 + x) * 4 + channel
                        contrast += Int(pixels[pixel]) - Int(pixels[pixel + 4])
                    }
                }
                return Double(contrast) / Double(28 * 4 * 255)
            }
        }
    }
}
