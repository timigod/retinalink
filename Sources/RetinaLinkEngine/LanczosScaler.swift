import CoreImage
import CoreVideo
import Metal
import RetinaLinkCore

/// Serial use on the capture queue. Core Image uses a Metal-backed Lanczos
/// kernel and writes directly to the destination IOSurface.
public final class LanczosScaler {
    private let context: CIContext
    private let pool: CVPixelBufferPool
    private let width: Int
    private let height: Int
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    public init(width: Int, height: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RetinaLinkError.operation("Metal Lanczos scaling is unavailable")
        }
        self.width = width
        self.height = height
        context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: p3, .outputColorSpace: p3,
                                                               .cacheIntermediates: false])
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw RetinaLinkError.operation("Could not create a Lanczos output pool")
        }
        self.pool = pool
    }

    public func scale(_ surface: VideoSurface) throws -> VideoSurface {
        let source = surface.pixelBuffer
        let sourceWidth = CVPixelBufferGetWidth(source), sourceHeight = CVPixelBufferGetHeight(source)
        if sourceWidth == width && sourceHeight == height { return surface }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess, let destination else {
            throw RetinaLinkError.operation("Could not allocate a Lanczos output surface")
        }
        let sx = Double(width) / Double(sourceWidth), sy = Double(height) / Double(sourceHeight)
        let input = CIImage(cvPixelBuffer: source, options: [.colorSpace: p3])
        let scaled = input.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy,
        ])
        context.render(scaled, to: destination, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: p3)
        StreamColorSpace.displayP3.tag(destination)
        CVBufferSetAttachment(destination, kCVImageBufferCGColorSpaceKey, p3, .shouldPropagate)
        return VideoSurface(destination)
    }
}
