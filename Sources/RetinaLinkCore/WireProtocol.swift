import Foundation

public enum WireError: Error, Equatable {
    case invalidMagic, unknownMessage, oversizedPayload, malformedPayload
}

public enum MessageType: UInt8, CaseIterable, Sendable {
    case receiverHello = 1, senderConfig, videoFrame, frameAck, cursorImage, cursorPosition
    case heartbeat, requestKeyframe, disconnect, losslessFrame
}

public struct WireFrame: Equatable, Sendable {
    public static let magic: UInt32 = 0x524C4E4B
    public static let headerSize = 16
    public static let maxPayloadSize = 32 * 1024 * 1024
    public let type: MessageType
    public let flags: UInt8
    public let sequence: UInt32
    public let payload: Data

    public init(type: MessageType, flags: UInt8 = 0, sequence: UInt32 = 0, payload: Data = Data()) {
        self.type = type
        self.flags = flags
        self.sequence = sequence
        self.payload = payload
    }

    public func encoded() throws -> Data {
        guard payload.count <= Self.maxPayloadSize else { throw WireError.oversizedPayload }
        var bytes = WireWriter(capacity: Self.headerSize + payload.count)
        bytes.put(Self.magic)
        bytes.put(type.rawValue)
        bytes.put(flags)
        bytes.put(UInt16(0))
        bytes.put(UInt32(payload.count))
        bytes.put(sequence)
        bytes.data.append(payload)
        return bytes.data
    }
}

public struct FrameBufferReader: Sendable {
    private var buffer = Data()
    private var offset = 0

    public init() {}

    public mutating func append(_ data: Data) throws -> [WireFrame] {
        buffer.append(data)
        var frames: [WireFrame] = []
        while buffer.count - offset >= WireFrame.headerSize {
            var header = WireReader(buffer, offset: offset)
            guard try header.get(UInt32.self) == WireFrame.magic else { throw WireError.invalidMagic }
            guard let type = try MessageType(rawValue: header.get(UInt8.self)) else { throw WireError.unknownMessage }
            let flags = try header.get(UInt8.self)
            _ = try header.get(UInt16.self)
            let length = try Int(header.get(UInt32.self))
            guard length <= WireFrame.maxPayloadSize else { throw WireError.oversizedPayload }
            let sequence = try header.get(UInt32.self)
            guard buffer.count - offset - WireFrame.headerSize >= length else { break }
            let payload = try header.take(length)
            frames.append(WireFrame(type: type, flags: flags, sequence: sequence, payload: payload))
            offset += WireFrame.headerSize + length
        }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset >= 65536 {
            buffer = Data(buffer.dropFirst(offset))
            offset = 0
        }
        return frames
    }
}

public enum HEVCProfile: String, Codable, CaseIterable, Sendable {
    case hevc444_10, hevc444_8, hevc420_10, hevc420_8

    public var bitDepth: Int { self == .hevc444_10 || self == .hevc420_10 ? 10 : 8 }
    public var is444: Bool { self == .hevc444_10 || self == .hevc444_8 }
    public var codecLabel: String {
        switch self {
        case .hevc444_10: "HEVC 4:4:4 10-bit"
        case .hevc444_8: "HEVC 4:4:4"
        case .hevc420_10: "HEVC 10-bit"
        case .hevc420_8: "HEVC"
        }
    }

    public static func negotiate(sender: [Self], receiver: [Self]?) -> Self? {
        allCases.first { sender.contains($0) && (receiver ?? [.hevc444_10]).contains($0) }
    }
}

public enum StreamColorSpace: String, Codable, Sendable {
    case displayP3, sRGB, rec709
}

public enum CursorMode: String, Codable, Sendable {
    case overlay, embedded
}

public struct ReceiverHello: Codable, Equatable, Sendable {
    public let name: String
    public let panelPixelWidth: Int
    public let panelPixelHeight: Int
    public let cursorPort: UInt16?
    public let ingressKind: LinkKind?
    public let supportsLossless: Bool?
    public let losslessVersion: UInt8?
    public var supportsProgressiveLossless: Bool { losslessVersion == LosslessFrame.protocolVersion }
    public let supportedProfiles: [HEVCProfile]?
    public let physicalWidthMm: Double?
    public let physicalHeightMm: Double?
    public let panelIsHiDPI: Bool?

    public init(name: String, panelPixelWidth: Int, panelPixelHeight: Int, cursorPort: UInt16?,
                ingressKind: LinkKind? = nil, supportsLossless: Bool? = nil, losslessVersion: UInt8? = nil,
                supportedProfiles: [HEVCProfile]? = nil, physicalWidthMm: Double? = nil,
                physicalHeightMm: Double? = nil, panelIsHiDPI: Bool? = nil) {
        self.name = name
        self.panelPixelWidth = panelPixelWidth
        self.panelPixelHeight = panelPixelHeight
        self.cursorPort = cursorPort
        self.ingressKind = ingressKind
        self.supportsLossless = supportsLossless
        self.losslessVersion = losslessVersion
        self.supportedProfiles = supportedProfiles
        self.physicalWidthMm = physicalWidthMm
        self.physicalHeightMm = physicalHeightMm
        self.panelIsHiDPI = panelIsHiDPI
    }
}

public struct SenderConfig: Codable, Equatable, Sendable {
    public let name: String
    public let width: UInt16
    public let height: UInt16
    public let profile: HEVCProfile
    public let colorSpace: StreamColorSpace
    public let linkKind: LinkKind
    public let cursorMode: CursorMode

    public init(name: String, width: UInt16, height: UInt16, profile: HEVCProfile, colorSpace: StreamColorSpace,
                linkKind: LinkKind, cursorMode: CursorMode) {
        self.name = name
        self.width = width
        self.height = height
        self.profile = profile
        self.colorSpace = colorSpace
        self.linkKind = linkKind
        self.cursorMode = cursorMode
    }
}

public struct DisconnectReason: Codable, Equatable, Sendable {
    public let reason: String

    public init(reason: String) { self.reason = reason }
}

public struct VideoFrame: Equatable, Sendable {
    public let frameID: UInt64
    public let captureTimeNs: UInt64
    public let isKeyframe: Bool
    public let width: UInt16
    public let height: UInt16
    public let hvcC: Data
    public let nalUnits: Data

    public init(frameID: UInt64, captureTimeNs: UInt64, isKeyframe: Bool, width: UInt16, height: UInt16,
                hvcC: Data, nalUnits: Data) {
        self.frameID = frameID
        self.captureTimeNs = captureTimeNs
        self.isKeyframe = isKeyframe
        self.width = width
        self.height = height
        self.hvcC = hvcC
        self.nalUnits = nalUnits
    }

    public func encoded() -> Data {
        var bytes = WireWriter(capacity: 28 + hvcC.count + nalUnits.count)
        bytes.put(frameID)
        bytes.put(captureTimeNs)
        bytes.put(UInt32((isKeyframe ? 1 : 0) | (hvcC.isEmpty ? 0 : 2)))
        bytes.put(width)
        bytes.put(height)
        bytes.put(UInt32(hvcC.count))
        bytes.data.append(hvcC)
        bytes.data.append(nalUnits)
        return bytes.data
    }

    public init(decoding data: Data) throws {
        var bytes = WireReader(data)
        frameID = try bytes.get(UInt64.self)
        captureTimeNs = try bytes.get(UInt64.self)
        let flags = try bytes.get(UInt32.self)
        isKeyframe = flags & 1 != 0
        width = try bytes.get(UInt16.self)
        height = try bytes.get(UInt16.self)
        let length = try Int(bytes.get(UInt32.self))
        guard width > 0, height > 0, (flags & 2 != 0) == (length > 0), bytes.remaining > length else {
            throw WireError.malformedPayload
        }
        hvcC = try bytes.take(length)
        nalUnits = try bytes.take(bytes.remaining)
    }
}

public struct FrameAck: Equatable, Sendable {
    public let frameID: UInt64
    public let captureTimeNs: UInt64
    public let decodeUs: UInt32
    public let receivedBytes: UInt32

    public init(frameID: UInt64, captureTimeNs: UInt64, decodeUs: UInt32, receivedBytes: UInt32) {
        self.frameID = frameID
        self.captureTimeNs = captureTimeNs
        self.decodeUs = decodeUs
        self.receivedBytes = receivedBytes
    }

    public func encoded() -> Data {
        var bytes = WireWriter(capacity: 24)
        bytes.put(frameID)
        bytes.put(captureTimeNs)
        bytes.put(decodeUs)
        bytes.put(receivedBytes)
        return bytes.data
    }

    public init(decoding data: Data) throws {
        guard data.count == 24 else { throw WireError.malformedPayload }
        var bytes = WireReader(data)
        frameID = try bytes.get(UInt64.self)
        captureTimeNs = try bytes.get(UInt64.self)
        decodeUs = try bytes.get(UInt32.self)
        receivedBytes = try bytes.get(UInt32.self)
    }
}

public struct CursorImage: Equatable, Sendable {
    public let cursorHash: UInt64
    public let width: UInt16
    public let height: UInt16
    public let hotSpotX: Float
    public let hotSpotY: Float
    public let scale: Float
    public let pngBytes: Data

    public init(cursorHash: UInt64, width: UInt16, height: UInt16, hotSpotX: Float, hotSpotY: Float, scale: Float,
                pngBytes: Data) {
        self.cursorHash = cursorHash
        self.width = width
        self.height = height
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
        self.scale = scale
        self.pngBytes = pngBytes
    }

    public func encoded() -> Data {
        var bytes = WireWriter(capacity: 24 + pngBytes.count)
        bytes.put(cursorHash)
        bytes.put(width)
        bytes.put(height)
        bytes.put(hotSpotX.bitPattern)
        bytes.put(hotSpotY.bitPattern)
        bytes.put(scale.bitPattern)
        bytes.data.append(pngBytes)
        return bytes.data
    }

    public init(decoding data: Data) throws {
        guard data.count <= 1024 * 1024 else { throw WireError.oversizedPayload }
        var bytes = WireReader(data)
        cursorHash = try bytes.get(UInt64.self)
        width = try bytes.get(UInt16.self)
        height = try bytes.get(UInt16.self)
        hotSpotX = try Float(bitPattern: bytes.get(UInt32.self))
        hotSpotY = try Float(bitPattern: bytes.get(UInt32.self))
        scale = try Float(bitPattern: bytes.get(UInt32.self))
        guard width > 0, height > 0, width <= 1024, height <= 1024, hotSpotX.isFinite, hotSpotY.isFinite,
              scale.isFinite, scale > 0, bytes.remaining > 0 else { throw WireError.malformedPayload }
        pngBytes = try bytes.take(bytes.remaining)
    }
}

public struct CursorPosition: Equatable, Sendable {
    public static let magic: UInt32 = 0x524C4350
    public static let packetSize = 24
    public let sequence: UInt32
    public let cursorHash: UInt64
    public let normX: Float
    public let normY: Float
    public let visible: Bool

    public init(sequence: UInt32, cursorHash: UInt64, normX: Float, normY: Float, visible: Bool) {
        self.sequence = sequence
        self.cursorHash = cursorHash
        self.normX = Self.clamp(normX)
        self.normY = Self.clamp(normY)
        self.visible = visible
    }

    public func encoded() -> Data {
        var bytes = WireWriter(capacity: Self.packetSize)
        bytes.put(Self.magic)
        bytes.put(sequence)
        bytes.put(cursorHash)
        // Normalized x is nonnegative. Its sign bit carries visibility so
        // both float coordinates and the full sequence fit in 24 bytes.
        bytes.put(normX.bitPattern | (visible ? 0 : 0x8000_0000))
        bytes.put(normY.bitPattern)
        return bytes.data
    }

    public init(decoding data: Data) throws {
        guard data.count == Self.packetSize else { throw WireError.malformedPayload }
        var bytes = WireReader(data)
        guard try bytes.get(UInt32.self) == Self.magic else { throw WireError.invalidMagic }
        sequence = try bytes.get(UInt32.self)
        cursorHash = try bytes.get(UInt64.self)
        let xBits = try bytes.get(UInt32.self)
        normX = Float(bitPattern: xBits & 0x7fff_ffff)
        normY = try Float(bitPattern: bytes.get(UInt32.self))
        visible = xBits & 0x8000_0000 == 0
        guard (0...1).contains(normX), (0...1).contains(normY) else { throw WireError.malformedPayload }
    }

    private static func clamp(_ value: Float) -> Float { value.isFinite && value > 0 ? min(value, 1) : 0 }
}

public struct Heartbeat: Equatable, Sendable {
    public let timestampNs: UInt64
    public let isReply: Bool

    public init(timestampNs: UInt64, isReply: Bool) {
        self.timestampNs = timestampNs
        self.isReply = isReply
    }

    public func encoded() -> Data {
        var bytes = WireWriter(capacity: 16)
        bytes.put(timestampNs)
        bytes.put(UInt8(isReply ? 1 : 0))
        bytes.data.append(Data(count: 7))
        return bytes.data
    }

    public init(decoding data: Data) throws {
        guard data.count == 16 else { throw WireError.malformedPayload }
        var bytes = WireReader(data)
        timestampNs = try bytes.get(UInt64.self)
        isReply = try bytes.get(UInt8.self) != 0
    }
}

public enum WireMessage: Equatable, Sendable {
    case receiverHello(ReceiverHello)
    case senderConfig(SenderConfig)
    case videoFrame(VideoFrame)
    case frameAck(FrameAck)
    case cursorImage(CursorImage)
    case cursorPosition(CursorPosition)
    case heartbeat(Heartbeat)
    case requestKeyframe
    case disconnect(DisconnectReason)
    case losslessFrame(LosslessFrame)

    public func frame(sequence: UInt32 = 0) throws -> WireFrame {
        let body: (MessageType, Data)
        switch self {
        case .receiverHello(let value): body = (.receiverHello, try JSONEncoder().encode(value))
        case .senderConfig(let value): body = (.senderConfig, try JSONEncoder().encode(value))
        case .videoFrame(let value): body = (.videoFrame, value.encoded())
        case .frameAck(let value): body = (.frameAck, value.encoded())
        case .cursorImage(let value): body = (.cursorImage, value.encoded())
        case .cursorPosition(let value): body = (.cursorPosition, value.encoded())
        case .heartbeat(let value): body = (.heartbeat, value.encoded())
        case .requestKeyframe: body = (.requestKeyframe, Data())
        case .losslessFrame(let value): body = (.losslessFrame, try value.encoded())
        case .disconnect(let value): body = (.disconnect, try JSONEncoder().encode(value))
        }
        return WireFrame(type: body.0, sequence: sequence, payload: body.1)
    }

    public init(frame: WireFrame) throws {
        let data = frame.payload
        switch frame.type {
        case .receiverHello: self = .receiverHello(try Self.json(ReceiverHello.self, data))
        case .senderConfig: self = .senderConfig(try Self.json(SenderConfig.self, data))
        case .videoFrame: self = .videoFrame(try VideoFrame(decoding: data))
        case .frameAck: self = .frameAck(try FrameAck(decoding: data))
        case .cursorImage: self = .cursorImage(try CursorImage(decoding: data))
        case .cursorPosition: self = .cursorPosition(try CursorPosition(decoding: data))
        case .heartbeat: self = .heartbeat(try Heartbeat(decoding: data))
        case .requestKeyframe:
            guard data.isEmpty else { throw WireError.malformedPayload }
            self = .requestKeyframe
        case .losslessFrame: self = .losslessFrame(try LosslessFrame(decoding: data))
        case .disconnect: self = .disconnect(try Self.json(DisconnectReason.self, data))
        }
    }

    private static func json<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= 64 * 1024 else { throw WireError.oversizedPayload }
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct WireWriter {
    var data: Data

    init(capacity: Int) { data = Data(capacity: capacity) }

    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

private struct WireReader {
    let data: Data
    var index: Data.Index
    var remaining: Int { data.endIndex - index }

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        index = data.startIndex + offset
    }

    mutating func get<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard remaining >= MemoryLayout<T>.size else { throw WireError.malformedPayload }
        let offset = index - data.startIndex
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
        index += MemoryLayout<T>.size
        return T(bigEndian: value)
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count <= remaining else { throw WireError.malformedPayload }
        let start = index
        index += count
        return data[start..<index]
    }
}

public enum LosslessAlgorithm: UInt8, Sendable {
    case lz4 = 0, lzfse = 1
}

public struct LosslessPatch: Equatable, Sendable {
    package static let headerBytes = 13
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16
    public let algorithm: LosslessAlgorithm
    public let compressedBytes: Data

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16, algorithm: LosslessAlgorithm = .lz4,
                compressedBytes: Data) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.algorithm = algorithm
        self.compressedBytes = compressedBytes
    }

    public var rect: PixelRect { PixelRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)) }
    package var payloadBytes: Int { Self.headerBytes + compressedBytes.count }
}

public struct LosslessFrame: Equatable, Sendable {
    public static let protocolVersion: UInt8 = 2
    package static let headerBytes = 30
    package static let maxChunkBytes = 3_500_000
    package static let maxSettleBytes = 28_000_000
    public let frameID: UInt64
    public let captureTimeNs: UInt64
    public let baseFrameID: UInt64
    public let width: UInt16
    public let height: UInt16
    public let flags: UInt8
    public let patches: [LosslessPatch]

    public var present: Bool { flags & 1 != 0 }
    public var resetsStaging: Bool { flags & 2 != 0 }

    public init(frameID: UInt64, captureTimeNs: UInt64, baseFrameID: UInt64, width: UInt16, height: UInt16,
                present: Bool, resetsStaging: Bool, patches: [LosslessPatch]) {
        self.frameID = frameID
        self.captureTimeNs = captureTimeNs
        self.baseFrameID = baseFrameID
        self.width = width
        self.height = height
        flags = (present ? 1 : 0) | (resetsStaging ? 2 : 0)
        self.patches = patches
    }

    public var payloadBytes: Int { patches.reduce(Self.headerBytes) { $0 + $1.payloadBytes } }

    package var hasValidBounds: Bool {
        guard width > 0, height > 0, flags & 0xfc == 0, frameID > baseFrameID,
              resetsStaging == (baseFrameID == 0), (1...64).contains(patches.count) else { return false }
        let rects = patches.map(\.rect)
        for (index, patch) in patches.enumerated() {
            let rect = rects[index]
            guard rect.width > 0, rect.height > 0, rect.maxX <= Int(width), rect.maxY <= Int(height),
                  !patch.compressedBytes.isEmpty,
                  !rects.suffix(from: index + 1).contains(where: rect.overlaps) else { return false }
        }
        return true
    }

    public func validate() throws {
        guard payloadBytes <= min(WireFrame.maxPayloadSize, Self.maxChunkBytes - WireFrame.headerSize) else { throw WireError.oversizedPayload }
        guard hasValidBounds else { throw WireError.malformedPayload }
    }

    fileprivate func encoded() throws -> Data {
        try validate()
        var writer = WireWriter(capacity: payloadBytes)
        writer.put(frameID)
        writer.put(captureTimeNs)
        writer.put(baseFrameID)
        writer.put(width)
        writer.put(height)
        writer.put(flags)
        writer.put(UInt8(patches.count))
        for patch in patches {
            writer.put(patch.x)
            writer.put(patch.y)
            writer.put(patch.width)
            writer.put(patch.height)
            writer.put(patch.algorithm.rawValue)
            writer.put(UInt32(patch.compressedBytes.count))
            writer.data.append(patch.compressedBytes)
        }
        return writer.data
    }

    fileprivate init(decoding data: Data) throws {
        guard data.count <= Self.maxChunkBytes - WireFrame.headerSize else { throw WireError.oversizedPayload }
        var reader = WireReader(data)
        frameID = try reader.get(UInt64.self)
        captureTimeNs = try reader.get(UInt64.self)
        baseFrameID = try reader.get(UInt64.self)
        width = try reader.get(UInt16.self)
        height = try reader.get(UInt16.self)
        flags = try reader.get(UInt8.self)
        let count = try reader.get(UInt8.self)
        guard (1...64).contains(count) else { throw WireError.malformedPayload }
        var patches: [LosslessPatch] = []
        for _ in 0..<count {
            let x = try reader.get(UInt16.self)
            let y = try reader.get(UInt16.self)
            let width = try reader.get(UInt16.self)
            let height = try reader.get(UInt16.self)
            guard let algorithm = LosslessAlgorithm(rawValue: try reader.get(UInt8.self)) else {
                throw WireError.malformedPayload
            }
            let length = try reader.get(UInt32.self)
            patches.append(LosslessPatch(x: x, y: y, width: width, height: height, algorithm: algorithm,
                                         compressedBytes: try reader.take(Int(length))))
        }
        guard reader.remaining == 0 else { throw WireError.malformedPayload }
        self.patches = patches
        try validate()
    }
}
