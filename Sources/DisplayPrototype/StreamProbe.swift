import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

private final class StreamProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "VirtualDisplayCapture", qos: .userInteractive)
    private let encoder: VTCompressionSession
    private let connection: PeerConnection?
    private let sendQueue = DispatchQueue(label: "iMacExtendedDisplay.SendFrames", qos: .userInteractive)
    private let lock = NSLock()
    private var accepting = true
    private var pending = 0
    private var received = 0
    private var encoded = 0
    private var dropped = 0
    private var bytes = 0
    private var failure: Error?

    init(width: Int, height: Int, connection: PeerConnection?) throws {
        self.connection = connection
        encoder = try makeEncoder(width: width, height: height)
    }

    deinit {
        VTCompressionSessionInvalidate(encoder)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if accepting { failure = error }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, let image = CMSampleBufferGetImageBuffer(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else { return }

        lock.lock()
        guard accepting, failure == nil else {
            lock.unlock()
            return
        }
        received += 1
        guard pending < 2 else {
            dropped += 1
            lock.unlock()
            return
        }
        pending += 1
        lock.unlock()

        let result = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            duration: CMSampleBufferGetDuration(sample), frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, flags, output in
            self?.record(status: status, flags: flags, output: output)
        }
        if result != noErr {
            record(status: result, flags: [], output: nil)
        }
    }

    private func record(status: OSStatus, flags: VTEncodeInfoFlags, output: CMSampleBuffer?) {
        if status == noErr, !flags.contains(.frameDropped), let output, let connection {
            sendQueue.async { [weak self] in
                do {
                    try connection.sendFrame(VideoWire.pack(output))
                    self?.recordEncoded(output)
                } catch {
                    self?.recordFailure(error)
                }
            }
            return
        }

        lock.lock()
        defer { lock.unlock() }
        pending -= 1
        if status != noErr {
            failure = EncoderProbeError.operation("Encode captured frame", status)
        } else if flags.contains(.frameDropped) {
            dropped += 1
        } else if let output, CMSampleBufferGetTotalSampleSize(output) > 0 {
            encoded += 1
            bytes += CMSampleBufferGetTotalSampleSize(output)
        } else {
            failure = EncoderProbeError.noOutput
        }
    }

    private func recordEncoded(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        pending -= 1
        encoded += 1
        bytes += CMSampleBufferGetTotalSampleSize(sample)
    }

    private func recordFailure(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        pending -= 1
        failure = error
    }

    func counts() -> (sent: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (encoded, dropped)
    }

    func checkFailure() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
    }

    func finish() throws -> String {
        queue.sync {
            lock.lock()
            accepting = false
            lock.unlock()
        }
        try requireSuccess(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid),
                           "Flush encoder")
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        guard encoded > 0 else { throw EncoderProbeError.noOutput }
        return "Five-second capture: \(received) complete frames, \(encoded) encoded, \(dropped) dropped, \(bytes) compressed bytes."
    }
}

@MainActor
func checkStream(displayID: CGDirectDisplayID, width: Int, height: Int,
                 link: WiredLink? = nil, listen: Bool = false) async throws -> String {
    try Task.checkCancellation()
    let connection: PeerConnection?
    if let link, listen {
        connection = try await waitForVideoPeer(link)
    } else {
        connection = try link?.makeConnection()
    }
    defer { connection?.cancel() }
    try Task.checkCancellation()
    if let connection {
        print("Negotiating the encrypted Thunderbolt connection…")
        if !listen { try connection.start() }
        print("Connected. Press Control-C to disconnect.")
    }
    let filter = try await virtualDisplayFilter(displayID: displayID)
    try Task.checkCancellation()
    let probe = try StreamProbe(width: width, height: height, connection: connection)
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.queueDepth = 3
    configuration.showsCursor = true

    let stream = SCStream(filter: filter, configuration: configuration, delegate: probe)
    try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: probe.queue)
    try await stream.startCapture()
    do {
        if let connection {
            var lastReport = ProcessInfo.processInfo.systemUptime
            var previous = probe.counts()
            while true {
                try await Task.sleep(nanoseconds: 200_000_000)
                try probe.checkFailure()
                try connection.checkConnected()
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - lastReport
                if elapsed >= 5 {
                    let current = probe.counts()
                    let framesPerSecond = Int((Double(current.sent - previous.sent) / elapsed).rounded())
                    print("Video: \(framesPerSecond) fps sent · \(current.dropped - previous.dropped) frames dropped in the last 5 sec")
                    previous = current
                    lastReport = now
                }
            }
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)
    } catch {
        connection?.cancel()
        try? await stream.stopCapture()
        throw error
    }
    try await stream.stopCapture()
    return try probe.finish()
}
