import CoreMedia
import CoreVideo
import Foundation
import RetinaLinkCore

extension StreamColorSpace {
    var tags: [CFString: CFString] {
        switch self {
        case .displayP3:
            [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_P3_D65,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ]
        case .sRGB:
            [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ]
        case .rec709:
            [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ]
        }
    }

    func tag(_ buffer: CVPixelBuffer) {
        for (key, value) in tags { CVBufferSetAttachment(buffer, key, value, .shouldPropagate) }
    }
}

public struct HEVCFormat: Equatable, Sendable {
    public let profileIDC: Int
    public let chromaFormat: Int
    public let bitDepthLuma: Int
    public let bitDepthChroma: Int

    public init(hvcC: Data) throws {
        let field = Array(hvcC.prefix(23))
        guard field.count == 23, field[0] == 1 else {
            throw RetinaLinkError.operation("Invalid HEVC configuration atom")
        }
        profileIDC = Int(field[1] & 0x1f)
        chromaFormat = Int(field[16] & 3)
        bitDepthLuma = 8 + Int(field[17] & 7)
        bitDepthChroma = 8 + Int(field[18] & 7)
    }

    func validate(profile: HEVCProfile) throws {
        let expectedIDC = profile.is444 ? 4 : (profile.bitDepth == 10 ? 2 : 1)
        guard profileIDC == expectedIDC, chromaFormat == (profile.is444 ? 3 : 1), bitDepthLuma == profile.bitDepth,
              bitDepthChroma == profile.bitDepth else {
            throw RetinaLinkError.operation(
                "Unexpected HEVC format: profile \(profileIDC), chroma \(chromaFormat), depths \(bitDepthLuma)/\(bitDepthChroma)"
            )
        }
    }
}
