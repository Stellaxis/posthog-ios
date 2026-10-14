#if os(iOS)
import Testing
import UIKit
@testable import PostHog

@Suite("Replay bitmap resolution", .serialized)
@MainActor
struct PostHogReplayCaptureScaleTest {
    @Test func visibleCapDoesNotChangeLiveViewScale() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let child = UIView(frame: parent.bounds)
        parent.addSubview(child)
        child.contentScaleFactor = 3
        let liveScale = child.contentScaleFactor
        #expect(PostHogExcludedLayerCapture.captureScale(for: parent.layer, nativeScale: 3) == 3)
        child.postHogReplayCaptureScale = 1
        #expect(PostHogExcludedLayerCapture.captureScale(for: parent.layer, nativeScale: 3) == 1)
        #expect(child.contentScaleFactor == liveScale)
        #expect(!child.postHogExcludeFromReplay)
        child.isHidden = true
        #expect(PostHogExcludedLayerCapture.captureScale(for: parent.layer, nativeScale: 3) == 3)
        child.isHidden = false
        child.removeFromSuperview()
        #expect(PostHogExcludedLayerCapture.captureScale(for: parent.layer, nativeScale: 3) == 3)
    }

    @Test func invalidCapRestoresNativeAndCapNeverUpscales() {
        let view = UIView()
        for invalid in [CGFloat.nan, .infinity, -1, 0.5] {
            view.postHogReplayCaptureScale = invalid
            #expect(view.postHogReplayCaptureScale == 0)
        }
        view.postHogReplayCaptureScale = 4
        #expect(PostHogExcludedLayerCapture.captureScale(for: view.layer, nativeScale: 2) == 2)
    }

    @Test func excludedDescendantsCannotAffectVisibleResolution() {
        let parent = UIView()
        parent.postHogExcludeFromReplay = true
        let child = UIView()
        child.postHogReplayCaptureScale = 1
        parent.addSubview(child)
        #expect(PostHogExcludedLayerCapture.captureScale(for: parent.layer, nativeScale: 3) == 3)
        parent.postHogReplayCaptureScale = 1
        #expect(PostHogExcludedLayerCapture.captureScale(for: parent.layer, nativeScale: 3) == 1)
    }

    @Test func referenceRequestsFollowVisibleOwnerLifecycle() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let owner = UIView(frame: window.bounds)
        window.addSubview(owner)
        owner.postHogReplayCaptureOnChange = true
        let initial = PostHogReplayCaptureRequests.snapshot(in: window).revisions
        #expect(initial.count == 1)
        owner.setNeedsPostHogReplayCapture()
        #expect(PostHogReplayCaptureRequests.snapshot(in: window).revisions != initial)
        owner.isHidden = true
        #expect(PostHogReplayCaptureRequests.snapshot(in: window).revisions.isEmpty)
        owner.isHidden = false
        owner.removeFromSuperview()
        #expect(PostHogReplayCaptureRequests.snapshot(in: window).revisions.isEmpty)
    }

    @Test func sceneTouchesDoNotInvalidateButControlsDo() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let owner = UIView(frame: window.bounds)
        window.addSubview(owner)
        let camera = UIView(frame: owner.bounds)
        owner.addSubview(camera)
        let button = UIButton(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        window.addSubview(button)
        owner.postHogReplayCaptureOnChange = true
        let initial = PostHogReplayCaptureRequests.snapshot(in: window).revisions
        PostHogReplayCaptureRequests.invalidateForControlTouch(in: window, target: camera)
        #expect(PostHogReplayCaptureRequests.snapshot(in: window).revisions == initial)
        PostHogReplayCaptureRequests.invalidateForControlTouch(in: window, target: button)
        #expect(PostHogReplayCaptureRequests.snapshot(in: window).revisions != initial)
    }

}
#endif
