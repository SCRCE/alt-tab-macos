import CoreGraphics

/// One stateful policy per tracked window, owned by the main thread. Static image analysis runs off-main.
struct ThumbnailCapturePolicy {
    enum Decision: Equatable {
        case accept
        case retry(UInt64)
        case discard
    }

    private var expectedSize: CGSize?
    private var retries = 0
    private var generation: UInt64 = 0
    private var pendingRetry: UInt64?
    private static let maxRetries = 3
    private static let partialFrameRatio = 0.9

    static func isPartial(_ actual: CGSize, _ expected: CGSize) -> Bool {
        actual.width < expected.width * partialFrameRatio || actual.height < expected.height *
            partialFrameRatio
    }

    static func contentPixelSize(_ rect: CGRect, scaleFactor: CGFloat, frameSize: CGSize) -> CGSize? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0, scaleFactor.isFinite, scaleFactor > 0,
              frameSize.width.isFinite, frameSize.height.isFinite, frameSize.width > 0,
              frameSize.height > 0 else { return nil }
        let pixels = CGRect(x: rect.minX * scaleFactor, y: rect.minY * scaleFactor,
                            width: rect.width * scaleFactor, height: rect.height * scaleFactor)
        guard pixels.origin.x.isFinite, pixels.origin.y.isFinite, pixels.width.isFinite,
              pixels.height.isFinite else { return nil }
        let clipped = pixels.intersection(CGRect(origin: .zero, size: frameSize))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return clipped.size
    }

    /// The screenshot API has no frame attachments. Sample its alpha off-main so a shelf-sized drawing
    /// inside a full-size transparent canvas cannot pass the image-dimensions check. Ignore faint shadows.
    static func contentPixelSize(_ image: CGImage) -> CGSize? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            let samples = bytes.bindMemory(to: UInt8.self)
            var minX = side
            var minY = side
            var maxX = -1
            var maxY = -1
            for y in 0 ..< side {
                for x in 0 ..< side where samples[(y * side + x) * 4 + 3] >= 32 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return .zero }
            return CGSize(width: CGFloat(maxX - minX + 1) * CGFloat(image.width) / CGFloat(side),
                          height: CGFloat(maxY - minY + 1) * CGFloat(image.height) / CGFloat(side))
        }
    }

    mutating func evaluate(actual: CGSize, expected: CGSize) -> Decision {
        if expectedSize != expected {
            expectedSize = expected
            reset()
        }
        guard Self.isPartial(actual, expected) else {
            reset()
            return .accept
        }
        guard pendingRetry == nil, retries < Self.maxRetries else { return .discard }
        retries += 1
        generation &+= 1
        pendingRetry = generation
        return .retry(generation)
    }

    mutating func takeRetry(_ token: UInt64) -> Bool {
        guard pendingRetry == token else { return false }
        pendingRetry = nil
        return true
    }

    private mutating func reset() {
        retries = 0
        pendingRetry = nil
        generation &+= 1
    }
}
