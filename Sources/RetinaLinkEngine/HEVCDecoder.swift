import CoreMedia
import CoreVideo
import Foundation
import RetinaLinkCore
import VideoToolbox
import Synchronization

public enum DecoderOutput: String, Codable, Sendable {
    case native, bgra
}

public struct DecodedVideoFrame: Sendable {
    public let surface: VideoSurface
    public let decodeUs: UInt32
}

// The serial queue owns the decompression session and format changes.
public final class HEVCDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RetinaLink.decode", qos: .userInteractive)
    private var holder: Session?
    private var activeHvcC: Data?
    private let config: SenderConfig
    private let output: DecoderOutput

    public static func supportedHardwareProfiles() -> [HEVCProfile] { hardwareProfiles }

    private static let hardwareProfiles: [HEVCProfile] = {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else { return [] }
        // Each pair is an hvcC atom and one generated 128×128 solid-color IDR.
        // Probe the decoder independently of which profiles this Mac can encode.
        let samples: [HEVCProfile: (String, String)] = [
            .hevc444_10: ("AQQIAAAAvAgAAAAAWvAA/P/6+gAACwOgAAEAF0ABDAH//wQIAAADALwIAAADAABaBDAkoQABAFRCAQEECAAAAwC8CAAAAwAAWpAChAQOCHbEAh3IpBBc/CehfUN6of1UEeqoJ9VUFeqqgv1VVBnqqqg31VVUHeqqqoP9VVVUCHqqqqpTcMDQED+EAgiiAAQAB0QBwHLwWyQACEQBUBy0gWyQAAhEAXAcshAWyQAJRAEkByzGBbJA",
                         "AAAAMigBiPCtkJ0xQFN8+5X9R7fyX9Hn9YDF9R7etub8jTQ7xLvTR98JELK6yJE5sT+HT4Y0"),
            .hevc444_8: ("AQQIAAAAvggAAAAAWvAA/P/4+AAACwOgAAEAF0ABDAH//wQIAAADAL4IAAADAABaBDAkoQABAFRCAQEECAAAAwC+CAAAAwAAWpAChAQOCHxAIdyKQQXPwnoX1DeqH9VBHqqCfVVBXqqoL9VVQZ6qqoN9VVVB3qqqqD/VVVVAh6qqqqU1DA0BA/hAIICiAAEAB0QBwHLwWyQ=",
                         "AAAANCgBrwrZCwSiQTFf9VHfqPJxbUS/+xNK9wr1HlMIGbhbXdtQtsUp8YPMzoiYkbMyzEmLnHg="),
            .hevc420_10: ("AQIgAAAAsAAAAAAAWvAA/P36+gAACwOgAAEAGEABDAH//wIgAAADALAAAAMAAAMAWgQwJKEAAQBUQgEBAiAAAAMAsAAAAwAAAwBaoBQgIHCO2IBDuRSCC5+E9C+ob1Q/qoI9VQT6qoK9VVBfqqqDPVVVBvqqqoO9VVVQf6qqqoEPVVVVSmoYGgIH8IBBogAEAAdEAcBy8FskAAhEAVActIFskAAIRAFwHLIQFskACUQBJAcsxgWyQA==",
                         "AAAANigBiPCtkLFKIEBTf6n+V/Ue3M2GAVnyNkSQJPUe3rbmxgdsqoe700ffGOP6FWSRObFAwjkmzg=="),
            .hevc420_8: ("AQFgAAAAsAAAAAAAWvAA/P34+AAACwOgAAEAGEABDAH//wFgAAADALAAAAMAAAMAWgQwJKEAAQBUQgEBAWAAAAMAsAAAAwAAAwBaoBQgIHCPiAQ7kUggufhPQvqG9UP6qCPVUE+qqCvVVQX6qqgz1VVQb6qqqDvVVVUH+qqqqBD1VVVUpuGBoCB/CAQQogABAAdEAcBy8Fsk",
                         "AAAAMSgBrwrZCbMQQTFfzjfqPKslZCZlrhT1HlMIGmN6u7agtsUp8WIHnREwkbMyyJSVgGA="),
        ]
        return HEVCProfile.allCases.filter { profile in
            guard let (atom, sample) = samples[profile],
                  let hvcC = Data(base64Encoded: atom), let nals = Data(base64Encoded: sample) else { return false }
            let config = SenderConfig(name: "Codec probe", width: 128, height: 128, profile: profile,
                                      colorSpace: .displayP3, linkKind: .wifi, cursorMode: .overlay)
            let decoder = HEVCDecoder(config: config)
            let frame = VideoFrame(frameID: 1, captureTimeNs: 1_000_000_000, isKeyframe: true,
                                   width: 128, height: 128, hvcC: hvcC, nalUnits: nals)
            let decoded = Mutex(false)
            do {
                try decoder.submit(frame, started: DispatchTime.now().uptimeNanoseconds) { result in
                    if case .success = result { decoded.withLock { $0 = true } }
                }
                guard let holder = decoder.holder,
                      VTDecompressionSessionWaitForAsynchronousFrames(holder.session) == noErr else { return false }
                return decoded.withLock { $0 }
            } catch { return false }
        }
    }()

    public init(config: SenderConfig, output: DecoderOutput = .native) {
        self.config = config
        self.output = output
    }

    public func decode(
        _ frame: VideoFrame, completion: @escaping @Sendable (Result<DecodedVideoFrame, Error>) -> Void
    ) throws {
        guard frame.width == config.width, frame.height == config.height else {
            throw RetinaLinkError.operation("HEVC frame dimensions do not match sender configuration")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            do { try submit(frame, started: started, completion: completion) }
            catch { completion(.failure(error)) }
        }
    }

    private func submit(_ frame: VideoFrame, started: UInt64,
                        completion: @escaping @Sendable (Result<DecodedVideoFrame, Error>) -> Void) throws {
        if frame.isKeyframe, !frame.hvcC.isEmpty, frame.hvcC != activeHvcC {
            try configure(hvcC: frame.hvcC)
        }
        guard let holder else { throw RetinaLinkError.operation("Decoder needs a keyframe with an hvcC atom") }
        let sample = try Self.sample(frame, format: holder.format)
        let status = VTDecompressionSessionDecodeFrame(
            holder.session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            let elapsed = UInt32(clamping: (DispatchTime.now().uptimeNanoseconds - started) / 1000)
            guard status == noErr, let image, CVPixelBufferGetIOSurface(image) != nil else {
                completion(.failure(RetinaLinkError.videoToolbox("HEVC IOSurface decode", status)))
                return
            }
            completion(.success(DecodedVideoFrame(surface: VideoSurface(image), decodeUs: elapsed)))
        }
        guard status == noErr else { throw RetinaLinkError.videoToolbox("HEVC frame decode submission", status) }
    }

    private func configure(hvcC: Data) throws {
        try HEVCFormat(hvcC: hvcC).validate(profile: config.profile)
        var extensions: [CFString: Any] = config.colorSpace.tags
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = ["hvcC": hvcC]
        var format: CMVideoFormatDescription?
        let result = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_HEVC, width: Int32(config.width),
            height: Int32(config.height), extensions: extensions as CFDictionary, formatDescriptionOut: &format
        )
        guard result == noErr, let format else { throw RetinaLinkError.videoToolbox("HEVC format description", result) }
        var attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        if output == .bgra { attributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_32BGRA }
        let decoder = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: decoder as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session
        )
        guard status == noErr, let session else { throw RetinaLinkError.videoToolbox("HEVC decoder creation", status) }
        holder = Session(session, format: format)
        activeHvcC = hvcC
    }

    private static func sample(_ frame: VideoFrame, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        let bytes = frame.nalUnits
        var block: CMBlockBuffer?
        let create = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard create == kCMBlockBufferNoErr, let block else {
            throw RetinaLinkError.videoToolbox("HEVC NAL buffer allocation", create)
        }
        let copy = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: $0.count)
        }
        guard copy == kCMBlockBufferNoErr else { throw RetinaLinkError.videoToolbox("HEVC NAL buffer copy", copy) }
        var result: CMSampleBuffer?
        var length = bytes.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: Int64(clamping: frame.captureTimeNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &length,
            sampleBufferOut: &result
        )
        guard status == noErr, let result else { throw RetinaLinkError.videoToolbox("HEVC sample creation", status) }
        return result
    }

    private final class Session {
        let session: VTDecompressionSession
        let format: CMVideoFormatDescription

        init(_ session: VTDecompressionSession, format: CMVideoFormatDescription) {
            self.session = session
            self.format = format
        }

        deinit { VTDecompressionSessionInvalidate(session) }
    }
}
