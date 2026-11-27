import CoreVideo
import Foundation
import RetinaLinkCore
import VideoToolbox

/// Converts ScreenCaptureKit's BGRA input to a hardware encoder surface,
/// using the chroma layout and bit depth requested by the encoder.
final class HEVCInput {
    let attributes: CFDictionary
    private let transfer: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    private let colorSpace: StreamColorSpace

    init(width: UInt16, height: UInt16, pixelFormat: OSType, colorSpace: StreamColorSpace) throws {
        self.colorSpace = colorSpace
        attributes = [
            kCVPixelBufferWidthKey: Int(width),
            kCVPixelBufferHeightKey: Int(height),
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(nil, nil, attributes, &pool)
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw RetinaLinkError.videoToolbox("HEVC input pool", poolStatus)
        }
        self.pool = pool
        var transfer: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        guard status == noErr, let transfer else {
            throw RetinaLinkError.videoToolbox("HEVC pixel transfer creation", status)
        }
        self.transfer = transfer
        let tags = colorSpace.tags
        for (property, tag) in [
            (kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimariesKey),
            (kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunctionKey),
            (kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrixKey),
        ] {
            guard let value = tags[tag] else { continue }
            let status = VTSessionSetProperty(transfer, key: property, value: value)
            guard status == noErr else { throw RetinaLinkError.videoToolbox("HEVC pixel transfer property", status) }
        }
    }

    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        var destination: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard allocation == kCVReturnSuccess, let destination else {
            throw RetinaLinkError.videoToolbox("HEVC input surface", allocation)
        }
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
        guard status == noErr else { throw RetinaLinkError.videoToolbox("BGRA to HEVC pixel transfer", status) }
        colorSpace.tag(destination)
        return destination
    }
}
