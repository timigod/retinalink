import RetinaLinkEngine

enum CodecProof {
    static func run() {
        print("hardwareEncode=\(HEVCEncoder.supportedHardwareProfiles().map(\.rawValue))")
        print("hardwareDecode=\(HEVCDecoder.supportedHardwareProfiles().map(\.rawValue))")
    }
}
