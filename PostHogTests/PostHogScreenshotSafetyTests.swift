#if os(iOS)
    import XCTest
    import UIKit
    @testable import PostHog

    /// Exercise the SDK renderer linked by the app, so a dependency update cannot
    /// silently restore the synchronous layer-tree fallback seen in Sentry 1KM.
    @MainActor
    final class PostHogScreenshotSafetyTests: XCTestCase {
        private final class ProbeLayer: CALayer {
            var renderCalls = 0

            override func render(in context: CGContext) {
                renderCalls += 1
            }
        }

        private final class ProbeView: UIView {
            override class var layerClass: AnyClass { ProbeLayer.self }
            var hierarchyCalls = 0
            var requestedScreenUpdates: [Bool] = []

            override func drawHierarchy(in rect: CGRect, afterScreenUpdates: Bool) -> Bool {
                XCTAssertTrue(Thread.isMainThread)
                hierarchyCalls += 1
                requestedScreenUpdates.append(afterScreenUpdates)
                UIColor.blue.setFill()
                UIRectFill(rect)
                return true
            }

            var layerRenderCalls: Int { (layer as! ProbeLayer).renderCalls }
        }

        func testUnsettledScreenshotDoesNotRenderOrProduceImage() {
            let view = ProbeView(frame: CGRect(x: 0, y: 0, width: 32, height: 48))

            XCTAssertNil(view.toImage(preferFidelityRenderer: false))
            XCTAssertEqual(view.hierarchyCalls, 0)
            XCTAssertEqual(view.layerRenderCalls, 0)
        }

        func testSettledScreenshotSucceedsAfterSkippingUnsettledFrame() throws {
            let view = ProbeView(frame: CGRect(x: 0, y: 0, width: 32, height: 48))
            XCTAssertNil(view.toImage(preferFidelityRenderer: false))

            let image = try XCTUnwrap(view.toImage())

            XCTAssertEqual(image.size, view.bounds.size)
            XCTAssertEqual(view.hierarchyCalls, 1)
            XCTAssertEqual(view.requestedScreenUpdates, [false])
            XCTAssertEqual(view.layerRenderCalls, 0)
        }

        func testNativePresentationScreenshotStillRequestsScreenUpdates() throws {
            let view = ProbeView(frame: CGRect(x: 0, y: 0, width: 32, height: 48))

            _ = try XCTUnwrap(view.toImage(afterScreenUpdates: true, preferFidelityRenderer: false))

            XCTAssertEqual(view.hierarchyCalls, 1)
            XCTAssertEqual(view.requestedScreenUpdates, [true])
            XCTAssertEqual(view.layerRenderCalls, 0)
        }

        func testFastMotionAndUnpairableMasksProduceNoScreenshot() {
            typealias Integration = PostHogReplayIntegration
            let owner = NSObject()
            let replacement = NSObject()
            let rect = CGRect(x: 0, y: 0, width: 32, height: 48)
            let before = [Integration.MaskedRegion(owner, rect: rect)]
            let samples: [([Integration.MaskedRegion]?, [Integration.MaskedRegion]?)] = [
                (before, [Integration.MaskedRegion(owner, rect: rect.offsetBy(dx: Integration.driftBudgetPoints + 1, dy: 0))]),
                (nil, before),
                (before, nil),
                (before, [Integration.MaskedRegion(replacement, rect: rect)]),
                (before, before + before)
            ]

            for (before, after) in samples {
                let verdict = Integration.settleVerdict(before: before, after: after)
                let view = ProbeView(frame: rect)

                XCTAssertFalse(verdict.band.usesFidelity)
                XCTAssertNil(view.toImage(preferFidelityRenderer: verdict.band.usesFidelity))
                XCTAssertEqual(view.hierarchyCalls, 0)
                XCTAssertEqual(view.layerRenderCalls, 0)
            }
        }

        func testEmptyViewProducesNoScreenshot() {
            let view = ProbeView(frame: .zero)

            XCTAssertNil(view.toImage())
            XCTAssertEqual(view.hierarchyCalls, 0)
            XCTAssertEqual(view.layerRenderCalls, 0)
        }
    }

#endif
