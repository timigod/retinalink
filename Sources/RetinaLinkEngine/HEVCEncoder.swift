import CoreMedia
import CoreVideo
import Foundation
import RetinaLinkCore
import VideoToolbox
import Synchronization

public struct EncodedVideoFrame: Sendable {
    public let frame: VideoFrame
    public let encodeUs: UInt32
}

// After initialization the serial queue owns all VideoToolbox calls and
// timestamp/IDR state. The callbacks only consume immutable encoded samples.
public final class HEVCEncoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RetinaLink.encode", qos: .userInteractive)
    private let holder: Session
    private let width: UInt16
    private let height: UInt16
    private let profile: HEVCProfile
    private let transfer: HEVCInput?
    private var keyframeRequested = true
    private var startTimeNs: UInt64?

    public static func supportedHardwareProfiles() -> [HEVCProfile] { hardwareProfiles }

    private static let hardwareProfiles: [HEVCProfile] = {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 128, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess
        else { return [] }
        memset(CVPixelBufferGetBaseAddress(buffer), 127, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let surface = VideoSurface(buffer)
        return HEVCProfile.allCases.filter { profile in
            let encoded = Mutex(false)
            do {
                let encoder = try HEVCEncoder(width: 128, height: 128, profile: profile, bitrateMbps: 4)
                try encoder.submit(surface, frameID: 1, captureTimeNs: 1_000_000_000,
                                   started: DispatchTime.now().uptimeNanoseconds) { result in
                    if case .success(let frame) = result, frame.frame.isKeyframe {
                        encoded.withLock { $0 = true }
                    }
                }
                guard VTCompressionSessionCompleteFrames(encoder.holder.session, untilPresentationTimeStamp: .invalid)
                    == noErr else { return false }
                return encoded.withLock { $0 }
            } catch { return false }
        }
    }()

    public init(width: UInt16, height: UInt16, profile: HEVCProfile = .hevc444_8,
                colorSpace: StreamColorSpace = .displayP3, bitrateMbps: Double) throws {
        self.width = width
        self.height = height
        self.profile = profile
        // BGRA can silently produce an 8-bit configuration on some
        // encoder paths even after setting the 10-bit profile.
        let pixelFormat: OSType? = switch profile {
        case .hevc444_10: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        case .hevc444_8: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case .hevc420_10: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .hevc420_8: nil
        }
        let transfer = try pixelFormat.map {
            try HEVCInput(width: width, height: height, pixelFormat: $0, colorSpace: colorSpace)
        }
        self.transfer = transfer
        var encoder: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var created: VTCompressionSession?
        func create() -> OSStatus {
            VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: encoder as CFDictionary, imageBufferAttributes: transfer?.attributes,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created
            )
        }
        var status = create()
        if status != noErr {
            encoder[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = nil
            status = create()
        }
        guard status == noErr, let created else { throw RetinaLinkError.videoToolbox("HEVC encoder creation", status) }
        holder = Session(created)
        let profileLevel = switch profile {
        case .hevc444_10: "HEVC_Main44410_AutoLevel"
        case .hevc444_8: "HEVC_Main444_AutoLevel"
        case .hevc420_10: "HEVC_Main10_AutoLevel"
        case .hevc420_8: "HEVC_Main_AutoLevel"
        }
        try set(kVTCompressionPropertyKey_ProfileLevel, profileLevel as CFString)
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 300 as CFNumber)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        let tags = colorSpace.tags
        try set(kVTCompressionPropertyKey_ColorPrimaries, tags[kCVImageBufferColorPrimariesKey]!)
        try set(kVTCompressionPropertyKey_TransferFunction, tags[kCVImageBufferTransferFunctionKey]!)
        try set(kVTCompressionPropertyKey_YCbCrMatrix, tags[kCVImageBufferYCbCrMatrixKey]!)
        try set(kVTCompressionPropertyKey_AverageBitRate, Self.bitrateValue(bitrateMbps) as CFNumber)
        // This property is optional across hardware encoder generations.
        try? set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
        let prepare = VTCompressionSessionPrepareToEncodeFrames(created)
        guard prepare == noErr else { throw RetinaLinkError.videoToolbox("HEVC encoder preparation", prepare) }
    }

    public func updateBitrate(_ mbps: Double) throws {
        let bitrate = try Self.bitrateValue(mbps)
        queue.async { [self] in try? set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber) }
    }

    public func forceKeyframe() {
        queue.async { [self] in keyframeRequested = true }
    }

    private static func bitrateValue(_ mbps: Double) throws -> Int {
        guard mbps.isFinite, (1...10_000).contains(mbps) else {
            throw RetinaLinkError.operation("Invalid HEVC bitrate")
        }
        return Int(mbps * 1_000_000)
    }

    public func encode(
        _ surface: VideoSurface, frameID: UInt64, captureTimeNs: UInt64,
        completion: @escaping @Sendable (Result<EncodedVideoFrame, Error>) -> Void
    ) throws {
        guard CVPixelBufferGetWidth(surface.pixelBuffer) == width,
              CVPixelBufferGetHeight(surface.pixelBuffer) == height else {
            throw RetinaLinkError.operation("Encoder received an unexpected pixel size")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            do {
                try submit(surface, frameID: frameID, captureTimeNs: captureTimeNs, started: started,
                           completion: completion)
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func submit(_ surface: VideoSurface, frameID: UInt64, captureTimeNs: UInt64, started: UInt64,
                        completion: @escaping @Sendable (Result<EncodedVideoFrame, Error>) -> Void) throws {
        let start = startTimeNs ?? captureTimeNs
        startTimeNs = start
        let timestamp = CMTime(value: Int64(clamping: captureTimeNs >= start ? captureTimeNs - start : 0),
                               timescale: 1_000_000_000)
        let properties = keyframeRequested ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let input = try transfer?.convert(surface.pixelBuffer) ?? surface.pixelBuffer
        let profile = self.profile
        let width = self.width
        let height = self.height
        let status = VTCompressionSessionEncodeFrame(
            holder.session, imageBuffer: input, presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: 60), frameProperties: properties, infoFlagsOut: nil
        ) { status, flags, sample in
            let elapsed = UInt32(clamping: (DispatchTime.now().uptimeNanoseconds - started) / 1000)
            guard status == noErr, !flags.contains(.frameDropped), let sample else {
                completion(.failure(RetinaLinkError.videoToolbox("HEVC frame encoding", status)))
                return
            }
            completion(Result {
                let frame = try Self.videoFrame(sample, frameID: frameID, captureTimeNs: captureTimeNs,
                                               width: width, height: height, profile: profile)
                return EncodedVideoFrame(frame: frame, encodeUs: elapsed)
            })
        }
        guard status == noErr else { throw RetinaLinkError.videoToolbox("HEVC frame submission", status) }
        keyframeRequested = false
    }

    private func set(_ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(holder.session, key: key, value: value)
        guard status == noErr else { throw RetinaLinkError.videoToolbox("HEVC encoder property \(key)", status) }
    }

    private static func videoFrame(
        _ sample: CMSampleBuffer, frameID: UInt64, captureTimeNs: UInt64,
        width: UInt16, height: UInt16, profile: HEVCProfile
    ) throws -> VideoFrame {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var hvcC = Data()
        if keyframe {
            guard let format = sample.formatDescription,
                  let atoms = CMFormatDescriptionGetExtension(
                      format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                  ) as? [String: Any], let bytes = atoms["hvcC"] as? Data else {
                throw RetinaLinkError.operation("Keyframe contains no hvcC atom")
            }
            try HEVCFormat(hvcC: bytes).validate(profile: profile)
            hvcC = bytes
        }
        guard let buffer = sample.dataBuffer else { throw RetinaLinkError.operation("HEVC output has no NAL units") }
        var nalUnits = Data(count: CMBlockBufferGetDataLength(buffer))
        let status = nalUnits.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw RetinaLinkError.videoToolbox("HEVC NAL extraction", status) }
        return VideoFrame(frameID: frameID, captureTimeNs: captureTimeNs, isKeyframe: keyframe, width: width,
                          height: height, hvcC: hvcC, nalUnits: nalUnits)
    }

    private final class Session {
        let session: VTCompressionSession
        init(_ session: VTCompressionSession) { self.session = session }
        deinit { VTCompressionSessionInvalidate(session) }
    }
}
