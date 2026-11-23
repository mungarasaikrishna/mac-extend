import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

func decodeFrame(_ sample: CMSampleBuffer) throws -> CVPixelBuffer {
    guard let format = CMSampleBufferGetFormatDescription(sample),
          CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
        throw EncoderProbeError.noOutput
    }

    var session: VTDecompressionSession?
    let attributes = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ] as CFDictionary
    try requireSuccess(
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                     decoderSpecification: nil, imageBufferAttributes: attributes,
                                     outputCallback: nil, decompressionSessionOut: &session),
        "Create H.264 decoder"
    )
    guard let session else { throw EncoderProbeError.noOutput }
    defer { VTDecompressionSessionInvalidate(session) }

    let lock = NSLock()
    var result: Result<CVPixelBuffer, EncoderProbeError>?
    try requireSuccess(
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            lock.lock()
            defer { lock.unlock() }
            if status != noErr {
                result = .failure(.operation("Decode frame callback", status))
            } else if let image {
                result = .success(image)
            } else {
                result = .failure(.noOutput)
            }
        },
        "Submit H.264 sample to decoder"
    )
    try requireSuccess(VTDecompressionSessionWaitForAsynchronousFrames(session), "Flush decoder")

    lock.lock()
    defer { lock.unlock() }
    guard let result else { throw EncoderProbeError.noOutput }
    return try result.get()
}
