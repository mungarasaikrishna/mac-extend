import CoreMedia
import Foundation

enum VideoWireError: LocalizedError {
    case invalidFrame
    var errorDescription: String? { "Invalid H.264 frame data." }
}

struct VideoWire {
    static let maximumFrameBytes = 8 * 1024 * 1024

    static func pack(_ sample: CMSampleBuffer) throws -> Data {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { throw VideoWireError.invalidFrame }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[String: Any]]
        let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        var result = Data([isNotSync ? 1 : 0])
        for index in 0..<2 {
            var bytes: UnsafePointer<UInt8>?
            var length = 0
            var count = 0
            var nalLength: Int32 = 0
            try requireSuccess(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &bytes,
                parameterSetSizeOut: &length, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalLength
            ), "Read H.264 parameter set")
            guard count == 2, nalLength == 4, let bytes, (1...65535).contains(length) else {
                throw VideoWireError.invalidFrame
            }
            result.append(integer(length))
            result.append(bytes, count: length)
        }

        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= maximumFrameBytes - result.count else {
            throw VideoWireError.invalidFrame
        }
        var payload = Data(count: length)
        try requireSuccess(payload.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                       destination: $0.baseAddress!)
        }, "Copy H.264 frame")
        result.append(payload)
        return result
    }

    static func unpack(_ data: Data, sequence: Int64) throws -> CMSampleBuffer {
        guard data.count <= maximumFrameBytes else { throw VideoWireError.invalidFrame }
        guard let flags = data.first, flags <= 1 else { throw VideoWireError.invalidFrame }
        var offset = data.startIndex + 1

        func readParameterSet() throws -> Data {
            guard data.endIndex - offset >= 4 else { throw VideoWireError.invalidFrame }
            let count = number(data[offset..<(offset + 4)])
            offset += 4
            guard (1...65535).contains(count), count <= data.endIndex - offset else {
                throw VideoWireError.invalidFrame
            }
            defer { offset += count }
            return data[offset..<(offset + count)]
        }

        let sps = try readParameterSet()
        let pps = try readParameterSet()
        let length = data.endIndex - offset
        guard length > 0 else { throw VideoWireError.invalidFrame }

        var format: CMFormatDescription?
        try requireSuccess(sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                                ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }, "Create H.264 stream description")
        guard let format else { throw VideoWireError.invalidFrame }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard VideoResolution.allCases.contains(where: {
            $0.width == Int(dimensions.width) && $0.height == Int(dimensions.height)
        }) else { throw VideoWireError.invalidFrame }

        var block: CMBlockBuffer?
        try requireSuccess(CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ), "Allocate received frame")
        guard let block else { throw VideoWireError.invalidFrame }
        try requireSuccess(data[offset...].withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }, "Copy received frame")

        var size = length
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: sequence, timescale: 60),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try requireSuccess(CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ), "Create received sample")
        guard let sample else { throw VideoWireError.invalidFrame }
        if flags == 1 {
            setAttachment(kCMSampleAttachmentKey_NotSync, on: sample)
        }
        return sample
    }

    static func setAttachment(_ key: CFString, on sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let values = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(values, Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    static func integer(_ value: Int) -> Data {
        var bigEndian = UInt32(value).bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func number(_ data: Data) -> Int {
        data.reduce(0) { ($0 << 8) | Int($1) }
    }
}
