import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum EncoderProbeError: LocalizedError {
    case operation(String, OSStatus)
    case noOutput

    var errorDescription: String? {
        switch self {
        case let .operation(name, status):
            return "\(name) failed with status \(status)."
        case .noOutput:
            return "VideoToolbox did not return a compressed frame."
        }
    }
}

func requireSuccess(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw EncoderProbeError.operation(operation, status) }
}

private func makeTestImage(resolution: VideoResolution) throws -> CVPixelBuffer {
    let width = resolution.width
    let height = resolution.height
    var pixelBuffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
    try requireSuccess(
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attributes, &pixelBuffer),
        "Create test image"
    )
    guard let pixelBuffer else { throw EncoderProbeError.noOutput }

    try requireSuccess(CVPixelBufferLockBaseAddress(pixelBuffer, []), "Lock test image")
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        if let bytes = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
            let length = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            memset(bytes, plane == 0 ? 235 : 128, length)
        }
    }
    try requireSuccess(CVPixelBufferUnlockBaseAddress(pixelBuffer, []), "Unlock test image")

    return pixelBuffer
}

func makeEncodedTestFrame(resolution: VideoResolution) throws -> CMSampleBuffer {
    try compressFrame(makeTestImage(resolution: resolution))
}

func checkEncoder(resolution: VideoResolution, roundTrip: Bool = false) throws {
    let width = resolution.width
    let height = resolution.height
    let sample = try makeEncodedTestFrame(resolution: resolution)
    let byteCount = CMSampleBufferGetTotalSampleSize(sample)
    print("Hardware H.264 encoded a \(width) × \(height) test frame (\(byteCount) bytes).")
    if roundTrip {
        let received = try VideoWire.unpack(VideoWire.pack(sample), sequence: 0)
        let decoded = try decodeFrame(received)
        guard CVPixelBufferGetWidth(decoded) == width, CVPixelBufferGetHeight(decoded) == height else {
            throw EncoderProbeError.noOutput
        }
        print("Decoded the H.264 frame at \(width) × \(height).")
        if resolution == .native4K {
            try checkEncoderFlow(resolution: resolution)
        }
    }
}

func encodeFrame(_ pixelBuffer: CVPixelBuffer) throws -> Int {
    CMSampleBufferGetTotalSampleSize(try compressFrame(pixelBuffer))
}

private func compressFrame(_ pixelBuffer: CVPixelBuffer) throws -> CMSampleBuffer {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let session = try makeEncoder(width: width, height: height)
    defer { VTCompressionSessionInvalidate(session) }

    let lock = NSLock()
    var output: Result<CMSampleBuffer, EncoderProbeError>?
    try requireSuccess(
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60), frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            lock.lock()
            defer { lock.unlock() }
            if status != noErr {
                output = .failure(.operation("Encode frame callback", status))
            } else if let sample, CMSampleBufferGetTotalSampleSize(sample) > 0 {
                output = .success(sample)
            } else {
                output = .failure(.noOutput)
            }
        },
        "Submit frame to encoder"
    )
    try requireSuccess(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid),
                       "Flush encoder")
    lock.lock()
    defer { lock.unlock() }
    guard let output else { throw EncoderProbeError.noOutput }
    return try output.get()
}

func makeEncoder(width: Int, height: Int) throws -> VTCompressionSession {
    var session: VTCompressionSession?
    let specification = [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: width < VideoResolution.native4K.width
    ] as CFDictionary
    try requireSuccess(
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                   codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: specification, imageBufferAttributes: nil,
                                   compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                   compressionSessionOut: &session),
        "Create hardware H.264 encoder"
    )
    guard let session else { throw EncoderProbeError.noOutput }

    try requireSuccess(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                                            value: kCFBooleanTrue), "Set real-time mode")
    try requireSuccess(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                                            value: kCFBooleanFalse), "Disable frame reordering")
    try requireSuccess(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                            value: NSNumber(value: 60)), "Set expected frame rate")
    let bitrate = width >= VideoResolution.native4K.width
        ? VideoResolution.native4K.bitrate : VideoResolution.standard.bitrate
    try requireSuccess(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                            value: NSNumber(value: bitrate)), "Set average bit rate")
    try requireSuccess(VTCompressionSessionPrepareToEncodeFrames(session), "Prepare encoder")

    return session
}

// Exercise the same two-frame limit as the live sender, with no flush between frames.
private func checkEncoderFlow(resolution: VideoResolution) throws {
    let image = try makeTestImage(resolution: resolution)
    let encoder = try makeEncoder(width: resolution.width, height: resolution.height)
    defer { VTCompressionSessionInvalidate(encoder) }

    let capacity = DispatchSemaphore(value: 2)
    let lock = NSLock()
    var callbackCount = 0
    var callbackError: EncoderProbeError?
    let frameCount = 60
    let start = ProcessInfo.processInfo.systemUptime
    for frame in 0..<frameCount {
        let nextFrameTime = start + Double(frame) / 60
        let delay = nextFrameTime - ProcessInfo.processInfo.systemUptime
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard capacity.wait(timeout: .now() + 2) == .success else {
            throw WiredLinkError.timeout("waiting for the 4K encoder to release an in-flight frame")
        }
        try requireSuccess(
            VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: image, presentationTimeStamp: CMTime(value: Int64(frame), timescale: 60),
                duration: CMTime(value: 1, timescale: 60), frameProperties: nil, infoFlagsOut: nil
            ) { status, flags, sample in
                lock.lock()
                if status != noErr {
                    callbackError = .operation("Encode 4K frame", status)
                } else if !flags.contains(.frameDropped), let sample, CMSampleBufferGetTotalSampleSize(sample) > 0 {
                    callbackCount += 1
                }
                lock.unlock()
                capacity.signal()
            },
            "Submit consecutive 4K frame"
        )
    }
    lock.lock()
    let beforeFlush = callbackCount
    lock.unlock()
    try requireSuccess(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid),
                       "Flush consecutive 4K frames")
    lock.lock()
    defer { lock.unlock() }
    if let callbackError { throw callbackError }
    guard callbackCount == frameCount, beforeFlush > 0 else { throw EncoderProbeError.noOutput }
    print("Encoded \(callbackCount) consecutive synthetic 4K frames; \(beforeFlush) completed before flushing.")
}
