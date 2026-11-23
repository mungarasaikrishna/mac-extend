import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum CaptureProbeError: LocalizedError {
    case permissionRequired
    case displayUnavailable
    case frameUnavailable
    case unexpectedSize(Int, Int)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Screen Recording permission is required. Grant access to the requesting app in System Settings > Privacy & Security, then rerun from Terminal."
        case .displayUnavailable:
            return "ScreenCaptureKit could not find the virtual display."
        case .frameUnavailable:
            return "ScreenCaptureKit did not return an image buffer."
        case let .unexpectedSize(width, height):
            return "ScreenCaptureKit returned an unexpected frame size: \(width) × \(height)."
        }
    }
}

@available(macOS 14.0, *)
@MainActor
func checkCapture(displayID: CGDirectDisplayID, width: Int, height: Int, encode: Bool) async throws -> String {
    let filter = try await virtualDisplayFilter(displayID: displayID)
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.showsCursor = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter,
                                                                    configuration: configuration)
    try Task.checkCancellation()
    guard let frame = CMSampleBufferGetImageBuffer(sample) else {
        throw CaptureProbeError.frameUnavailable
    }
    let frameWidth = CVPixelBufferGetWidth(frame)
    let frameHeight = CVPixelBufferGetHeight(frame)
    guard frameWidth == width, frameHeight == height else {
        throw CaptureProbeError.unexpectedSize(frameWidth, frameHeight)
    }
    if encode {
        let byteCount = try encodeFrame(frame)
        return "Hardware H.264 encoded a \(width) × \(height) frame captured from the virtual display (\(byteCount) bytes)."
    }
    return "Captured one frame from the virtual display in memory."
}

@MainActor
func virtualDisplayFilter(displayID: CGDirectDisplayID) async throws -> SCContentFilter {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        throw CaptureProbeError.permissionRequired
    }

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw CaptureProbeError.displayUnavailable
    }

    return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
}
