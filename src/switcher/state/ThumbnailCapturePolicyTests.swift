import CoreGraphics
import XCTest

final class ThumbnailCapturePolicyTests: XCTestCase {
    private let expected = CGSize(width: 400, height: 300)
    private let partial = CGSize(width: 100, height: 75)

    private func retry(_ policy: inout ThumbnailCapturePolicy, actual: CGSize,
                       expected: CGSize) throws -> UInt64 {
        guard case let .retry(token) = policy.evaluate(actual: actual, expected: expected) else {
            XCTFail("A partial frame with retry budget must request a retry")
            throw NSError(domain: "ThumbnailCapturePolicyTests", code: 1)
        }
        return token
    }

    func testFirstPartialFrameIsNotAccepted() throws {
        var policy = ThumbnailCapturePolicy()
        _ = try retry(&policy, actual: partial, expected: expected)
    }

    func testExhaustionKeepsGoodThumbnailAndDoesNotRestartRetries() throws {
        var policy = ThumbnailCapturePolicy()
        XCTAssertEqual(policy.evaluate(actual: expected, expected: expected), .accept)
        var displayed = expected
        for _ in 0 ..< 3 {
            let token = try retry(&policy, actual: partial, expected: expected)
            XCTAssertTrue(policy.takeRetry(token))
        }
        for _ in 0 ..< 20 {
            let decision = policy.evaluate(actual: partial, expected: expected)
            if decision == .accept {
                displayed = partial
            }
            XCTAssertEqual(decision, .discard)
        }
        XCTAssertEqual(displayed, expected)
    }

    func testConcurrentPartialResultsShareOnePendingRetry() throws {
        var policy = ThumbnailCapturePolicy()
        let token = try retry(&policy, actual: partial, expected: expected)
        for _ in 0 ..< 8 { XCTAssertEqual(policy.evaluate(actual: partial, expected: expected), .discard) }
        XCTAssertTrue(policy.takeRetry(token))
        XCTAssertFalse(policy.takeRetry(token))
        _ = try retry(&policy, actual: partial, expected: expected)
    }

    func testGoodFrameInvalidatesPendingRetryAndRestoresBudget() throws {
        var policy = ThumbnailCapturePolicy()
        let old = try retry(&policy, actual: partial, expected: expected)
        XCTAssertEqual(policy.evaluate(actual: expected, expected: expected), .accept)
        let current = try retry(&policy, actual: partial, expected: expected)
        XCTAssertFalse(policy.takeRetry(old))
        XCTAssertTrue(policy.takeRetry(current))
    }

    func testResizeAcceptsLegitimatelySmallerWindow() throws {
        var policy = ThumbnailCapturePolicy()
        let old = try retry(&policy, actual: partial, expected: expected)
        XCTAssertEqual(policy.evaluate(actual: partial, expected: partial), .accept)
        XCTAssertFalse(policy.takeRetry(old))
    }

    func testGeometryChangeInvalidatesRetryAndResetsExhaustedBudget() throws {
        var policy = ThumbnailCapturePolicy()
        for _ in 0 ..< 3 {
            let token = try retry(&policy, actual: partial, expected: expected)
            XCTAssertTrue(policy.takeRetry(token))
        }
        XCTAssertEqual(policy.evaluate(actual: partial, expected: expected), .discard)
        let larger = CGSize(width: 800, height: 600)
        let old = try retry(&policy, actual: partial, expected: larger)
        let current = try retry(&policy, actual: partial, expected: expected)
        XCTAssertFalse(policy.takeRetry(old))
        XCTAssertTrue(policy.takeRetry(current))
    }

    func testGradualDegradationIsComparedToExpectedSize() {
        var policy = ThumbnailCapturePolicy()
        XCTAssertEqual(policy.evaluate(actual: expected, expected: expected), .accept)
        XCTAssertEqual(policy.evaluate(actual: CGSize(width: 360, height: 270), expected: expected), .accept)
        XCTAssertNotEqual(
            policy.evaluate(actual: CGSize(width: 324, height: 243), expected: expected),
            .accept
        )
    }

    func testRoundingAndLargerCapturesRemainAcceptable() {
        var policy = ThumbnailCapturePolicy()
        XCTAssertEqual(policy.evaluate(actual: CGSize(width: 399, height: 299), expected: expected), .accept)
        XCTAssertEqual(policy.evaluate(actual: CGSize(width: 800, height: 600), expected: expected), .accept)
        XCTAssertNotEqual(
            policy.evaluate(actual: CGSize(width: 400, height: 100), expected: expected),
            .accept
        )
    }

    func testNewWindowDoesNotInheritExhaustedPolicy() throws {
        var old = ThumbnailCapturePolicy()
        for _ in 0 ..< 3 {
            let token = try retry(&old, actual: partial, expected: expected)
            XCTAssertTrue(old.takeRetry(token))
        }
        var replacement = ThumbnailCapturePolicy()
        _ = try retry(&replacement, actual: partial, expected: expected)
    }

    func testSmallContentInsideFullCanvasIsRejectedEvenAsFirstCapture() throws {
        let image = try image(content: CGRect(x: 16, y: 12, width: 32, height: 24))
        let content = try XCTUnwrap(ThumbnailCapturePolicy.contentPixelSize(image))
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 96)
        XCTAssertEqual(content.width, 32, accuracy: 2)
        XCTAssertEqual(content.height, 24, accuracy: 2)
        var policy = ThumbnailCapturePolicy()
        _ = try retry(&policy, actual: content, expected: CGSize(width: 128, height: 96))
    }

    func testFullContentInAlphaImageIsAccepted() throws {
        let image = try image(content: CGRect(x: 0, y: 0, width: 128, height: 96))
        let content = try XCTUnwrap(ThumbnailCapturePolicy.contentPixelSize(image))
        var policy = ThumbnailCapturePolicy()
        XCTAssertEqual(policy.evaluate(actual: content, expected: CGSize(width: 128, height: 96)), .accept)
    }

    func testFaintShadowDoesNotMakeTinyContentLookFullSize() throws {
        let image = try image(content: CGRect(x: 16, y: 12, width: 32, height: 24), backgroundAlpha: 0.03)
        let content = try XCTUnwrap(ThumbnailCapturePolicy.contentPixelSize(image))
        XCTAssertEqual(content.width, 32, accuracy: 2)
        XCTAssertEqual(content.height, 24, accuracy: 2)
    }

    func testTransparentCaptureIsPartial() throws {
        let image = try image(content: .zero)
        let content = try XCTUnwrap(ThumbnailCapturePolicy.contentPixelSize(image))
        XCTAssertEqual(content, .zero)
        XCTAssertTrue(ThumbnailCapturePolicy.isPartial(content, expected))
    }

    func testOpaqueImageUsesImageDimensionsInsteadOfAlphaSampling() throws {
        let image = try image(content: CGRect(x: 0, y: 0, width: 128, height: 96), opaque: true)
        XCTAssertNil(ThumbnailCapturePolicy.contentPixelSize(image))
    }

    func testMetadataUsesDisplayScaleAndClipsToBuffer() {
        let size = ThumbnailCapturePolicy.contentPixelSize(CGRect(x: 0, y: 0, width: 200, height: 150),
                                                           scaleFactor: 2, frameSize: expected)
        XCTAssertEqual(size, expected)
        let clipped = ThumbnailCapturePolicy.contentPixelSize(CGRect(x: 50, y: 0, width: 200, height: 150),
                                                              scaleFactor: 2, frameSize: expected)
        XCTAssertEqual(clipped, CGSize(width: 300, height: 300))
    }

    func testMetadataDetectsSmallDrawingAndRejectsInvalidValues() throws {
        let content = try XCTUnwrap(ThumbnailCapturePolicy.contentPixelSize(
            CGRect(x: 0, y: 0, width: 50, height: 37.5),
            scaleFactor: 2,
            frameSize: expected
        ))
        XCTAssertEqual(content, partial)
        XCTAssertTrue(ThumbnailCapturePolicy.isPartial(content, expected))
        for scale: CGFloat in [0, -.infinity, .nan] {
            XCTAssertNil(ThumbnailCapturePolicy.contentPixelSize(CGRect(x: 0, y: 0, width: 50, height: 40),
                                                                 scaleFactor: scale, frameSize: expected))
        }
        XCTAssertNil(ThumbnailCapturePolicy.contentPixelSize(CGRect(x: 900, y: 900, width: 50, height: 40),
                                                             scaleFactor: 2, frameSize: expected))
    }

    private func image(content: CGRect, backgroundAlpha: CGFloat = 0,
                       opaque: Bool = false) throws -> CGImage {
        let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8,
                                              bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: alpha.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: backgroundAlpha))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(content)
        return try XCTUnwrap(context.makeImage())
    }
}
