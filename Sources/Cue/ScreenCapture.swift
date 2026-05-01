import AppKit
import ScreenCaptureKit

enum ScreenCapture {
    /// Max dimension (longer side) for captured screenshots. Matches Anthropic's
    /// recommended image sizing — bigger costs more tokens with no quality gain.
    /// Computer Use works best at these specific resolutions (matches training data).
    /// Pick the one closest to the display's aspect ratio.
    private static let computerUseSizes: [(CGSize)] = [
        CGSize(width: 1024, height: 768),   // 4:3
        CGSize(width: 1280, height: 800),   // 16:10
        CGSize(width: 1366, height: 768),   // 16:9
    ]
    static let jpegQuality = 0.88

    enum CaptureError: LocalizedError {
        case noDisplay
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available to capture"
            case .encodingFailed: return "Failed to encode screenshot"
            }
        }
    }

    /// Capture the main display and return JPEG data + the size used.
    /// The size is the Computer Use–compatible resolution, needed to convert
    /// tool_use coordinates back to screen coordinates.
    static func capture(excludingWindowIDs: [CGWindowID] = []) async throws -> (Data, CGSize) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let targetSize = bestComputerUseSize(for: CGSize(width: display.width, height: display.height))
        let resized = resize(image, to: targetSize)
        let rep = NSBitmapImageRep(cgImage: resized)
        guard let data = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        ) else {
            throw CaptureError.encodingFailed
        }
        return (data, targetSize)
    }

    private static func bestComputerUseSize(for display: CGSize) -> CGSize {
        let aspect = display.width / display.height
        return computerUseSizes.min(by: {
            abs($0.width / $0.height - aspect) < abs($1.width / $1.height - aspect)
        }) ?? computerUseSizes[1]
    }

    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage {
        let newW = Int(size.width)
        let newH = Int(size.height)

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
}
