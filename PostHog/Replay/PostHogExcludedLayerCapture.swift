#if os(iOS)
import UIKit
import AVFoundation
import ObjectiveC

private var replayExclusionKey: UInt8 = 0
private var replayCaptureScaleKey: UInt8 = 0

public extension UIView {
    /// Keep touch recording active, but capture this window only when controls
    /// change. Call setNeedsPostHogReplayCapture() after meaningful UI changes.
    /// Configure and invalidate on the main thread, as with other UIView APIs.
    @objc var postHogReplayCaptureOnChange: Bool {
        get { PostHogReplayCaptureRequests.isEnabled(for: self) }
        set { PostHogReplayCaptureRequests.setEnabled(newValue, for: self) }
    }

    /// Coalesces interface changes into a fresh reference image after settling.
    /// Elapsed-time labels and camera frames must not call this method.
    @objc func setNeedsPostHogReplayCapture() {
        PostHogReplayCaptureRequests.invalidate(self)
    }

    /// Caps replay bitmap resolution for this visible subtree's window. Zero
    /// (the default) preserves native resolution. Values below one or nonfinite
    /// values restore the default. Set on the AR container, not a global window.
    /// This affects replay only; live view rendering and exclusion are unchanged.
    @objc var postHogReplayCaptureScale: CGFloat {
        get {
            (objc_getAssociatedObject(layer, &replayCaptureScaleKey) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        }
        set {
            let value = newValue.isFinite && newValue >= 1 ? newValue : 0
            objc_setAssociatedObject(layer, &replayCaptureScaleKey, NSNumber(value: Double(value)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Removes this view's drawing subtree from replay screenshots while preserving
    /// siblings drawn above it. Unlike a rectangular mask, overlapping controls remain.
    /// Set on the native content view, never on the container holding its controls.
    @objc var postHogExcludeFromReplay: Bool {
        get { (objc_getAssociatedObject(layer, &replayExclusionKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(layer, &replayExclusionKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// Weak owners avoid retaining a dismissed AR screen. Checking a registered
/// owner and its ancestors does not traverse or rasterize the window's layers.
enum PostHogReplayCaptureRequests {
    static let changed = Notification.Name("PostHogReplayCaptureRequests.changed")
    static let settleDelay: TimeInterval = 0.25

    private final class Request {
        let id = UUID()
        var revision: UInt64 = 0
        var changedAt = ProcessInfo.processInfo.systemUptime
    }
    private static let owners = NSMapTable<UIView, Request>.weakToStrongObjects()

    struct Snapshot {
        let revisions: [UUID: UInt64]
        let readyAt: TimeInterval
    }

    static func isEnabled(for view: UIView) -> Bool { owners.object(forKey: view) != nil }

    static func setEnabled(_ enabled: Bool, for view: UIView) {
        precondition(Thread.isMainThread)
        if enabled {
            guard owners.object(forKey: view) == nil else { return }
            owners.setObject(Request(), forKey: view)
        } else {
            owners.removeObject(forKey: view)
        }
        if let window = view.window {
            NotificationCenter.default.post(name: changed, object: window)
        }
    }

    static func invalidate(_ view: UIView) {
        precondition(Thread.isMainThread)
        guard let request = owners.object(forKey: view) else { return }
        request.revision &+= 1
        request.changedAt = ProcessInfo.processInfo.systemUptime
        if let window = view.window {
            NotificationCenter.default.post(name: changed, object: window)
        }
    }

    /// A control outside the camera container may own nested SwiftUI state that
    /// the app cannot observe. Refresh after that interaction; scene taps do not.
    static func invalidateForControlTouch(in window: UIWindow, target: UIView?) {
        guard let target else { return }
        let visibleOwners = owners.keyEnumerator().allObjects.compactMap { $0 as? UIView }
            .filter { $0.window === window && !$0.isHidden && $0.alpha > 0 }
        guard !visibleOwners.isEmpty,
              !visibleOwners.contains(where: { target.isDescendant(of: $0) }) else { return }
        for owner in visibleOwners { invalidate(owner) }
    }

    static func invalidateForKeyboardChange() {
        for case let owner as UIView in owners.keyEnumerator().allObjects where owner.window != nil {
            invalidate(owner)
        }
    }

    static func snapshot(in window: UIWindow) -> Snapshot {
        precondition(Thread.isMainThread)
        var revisions: [UUID: UInt64] = [:]
        var readyAt: TimeInterval = 0
        for case let view as UIView in owners.keyEnumerator().allObjects {
            guard view.window === window,
                  window.bounds.intersects(view.convert(view.bounds, to: window)) else { continue }
            var ancestor: UIView? = view
            var visible = true
            while let current = ancestor, current !== window {
                if current.isHidden || (current.alpha <= 0 && (current.layer.presentation()?.opacity ?? 0) <= 0) {
                    visible = false
                    break
                }
                ancestor = current.superview
            }
            guard visible, let request = owners.object(forKey: view) else { continue }
            revisions[request.id] = request.revision
            readyAt = max(readyAt, request.changedAt + settleDelay)
        }
        return Snapshot(revisions: revisions, readyAt: readyAt)
    }
}

/// Detached capture: no live view/layer is hidden, reparented, or modified. Native
/// stream layers are replaced before any rendering, so their pixels never enter
/// the replay image. Ordinary descendants and overlapping siblings are retained.
/// Full-tree layer rendering previously hung on SwiftUI effects. Rasterize only
/// one childless layer at a time, then composite plain bitmap layers instead.
enum PostHogExcludedLayerCapture {
    // Do not let invisible retained media force unrelated pages into filtered
    // capture. A fading layer still counts while its presentation is visible.
    private static func isInvisible(_ layer: CALayer) -> Bool {
        if layer.isHidden { return true }
        return layer.opacity <= 0 && (layer.presentation()?.opacity ?? layer.opacity) <= 0
    }

    static func containsExclusion(_ layer: CALayer) -> Bool {
        if isInvisible(layer) { return false }
        if isExcluded(layer) || isDecorativeSheetShadow(layer) { return true }
        return layer.sublayers?.contains(where: containsExclusion) ?? false
    }

    // UIKit's sheet shadow is a decorative bitmap with bounds extending across
    // the controls. Omit its pixels rather than unmasking any image content.
    // Unknown hierarchies retain the ordinary image masking policy.
    static func isDecorativeSheetShadow(_ layer: CALayer) -> Bool {
        guard let view = layer.delegate as? UIImageView,
              String(describing: type(of: view)) == "_UIRoundedRectShadowView",
              let parent = view.superview,
              String(describing: type(of: parent)) == "UIDropShadowView",
              view.subviews.isEmpty, (layer.sublayers ?? []).isEmpty else { return false }
        return true
    }

    private static func isExcluded(_ layer: CALayer) -> Bool {
        // Native AV playback may move between windows during full-screen transitions.
        // Exclude the video layer by public type wherever it is mounted; controls
        // remain independent siblings. Never read this layer's opaque contents.
        layer is AVPlayerLayer || layer is AVSampleBufferDisplayLayer
            || ((objc_getAssociatedObject(layer, &replayExclusionKey) as? Bool) ?? false)
    }

    /// Read model-layer policy while applying the same visibility rules as capture.
    /// Excluded descendants cannot contribute pixels or a resolution request.
    static func captureScale(for layer: CALayer, nativeScale: CGFloat) -> CGFloat {
        guard !isInvisible(layer) else { return nativeScale }
        let requested = (objc_getAssociatedObject(layer, &replayCaptureScaleKey) as? NSNumber)?.doubleValue ?? 0
        var scale = requested >= 1 ? min(nativeScale, CGFloat(requested)) : nativeScale
        if scale <= 1 || isExcluded(layer) { return scale }
        for child in layer.sublayers ?? [] {
            scale = min(scale, captureScale(for: child, nativeScale: scale))
            if scale <= 1 { break }
        }
        return scale
    }

    static func image(of view: UIView) -> UIImage? {
        // A background screenshot must never fall back to unfiltered capture.
        guard Thread.isMainThread else { return nil }
        let nativeScale = (view as? UIWindow ?? view.window)?.screen.scale ?? 1
        let scale = captureScale(for: view.layer, nativeScale: nativeScale)
        let budget = Budget(pixelLimit: view.bounds.width * view.bounds.height * scale * scale * 12)
        guard let tree = copyTree(view.layer, scale: scale, budget: budget) else { return nil }
        return PostHogGraphicsImageRenderer(size: view.bounds.size, scale: scale).image { context in
            // Masked replay already downsamples to point resolution without
            // interpolation. Avoid filtering the same native bitmap layers here.
            if scale == 1 { context.interpolationQuality = .none }
            tree.render(in: context)
        }
    }

    private final class Budget {
        let started = ProcessInfo.processInfo.systemUptime
        let pixelLimit: CGFloat
        var pixels: CGFloat = 0
        var layers = 0
        init(pixelLimit: CGFloat) { self.pixelLimit = pixelLimit }
        func admit(_ size: CGSize, scale: CGFloat) -> Bool {
            layers += 1
            pixels += size.width * size.height * scale * scale
            return layers <= 1200 && pixels.isFinite && pixels <= pixelLimit
                && ProcessInfo.processInfo.systemUptime - started < 0.05
        }
    }

    /// Copy only documented drawing properties. Geometry and sibling stacking
    /// belong to the outer shell; this layer never has children or effects.
    private static func ownDrawingLayer(_ source: CALayer) -> CALayer? {
        let own: CALayer
        if let shape = source as? CAShapeLayer {
            let copy = CAShapeLayer()
            copy.path = shape.path
            copy.fillColor = shape.fillColor
            copy.strokeColor = shape.strokeColor
            copy.fillRule = shape.fillRule
            copy.lineWidth = shape.lineWidth
            copy.lineCap = shape.lineCap
            copy.lineJoin = shape.lineJoin
            copy.miterLimit = shape.miterLimit
            copy.lineDashPhase = shape.lineDashPhase
            copy.lineDashPattern = shape.lineDashPattern
            copy.strokeStart = shape.strokeStart
            copy.strokeEnd = shape.strokeEnd
            own = copy
        } else if let text = source as? CATextLayer {
            let copy = CATextLayer()
            copy.string = text.string
            copy.font = text.font
            copy.fontSize = text.fontSize
            copy.foregroundColor = text.foregroundColor
            copy.alignmentMode = text.alignmentMode
            copy.truncationMode = text.truncationMode
            copy.isWrapped = text.isWrapped
            own = copy
        } else if let gradient = source as? CAGradientLayer {
            let copy = CAGradientLayer()
            copy.colors = gradient.colors
            copy.locations = gradient.locations
            copy.startPoint = gradient.startPoint
            copy.endPoint = gradient.endPoint
            copy.type = gradient.type
            own = copy
        } else if type(of: source) == CALayer.self || source.contents != nil {
            own = CALayer()
        } else {
            return nil
        }
        own.bounds = source.bounds
        own.contents = source.contents
        own.contentsScale = source.contentsScale
        own.contentsRect = source.contentsRect
        own.contentsCenter = source.contentsCenter
        own.contentsGravity = source.contentsGravity
        own.backgroundColor = source.backgroundColor
        own.borderWidth = source.borderWidth
        own.borderColor = source.borderColor
        own.cornerRadius = source.cornerRadius
        own.maskedCorners = source.maskedCorners
        own.cornerCurve = source.cornerCurve
        own.masksToBounds = source.masksToBounds
        own.isGeometryFlipped = source.isGeometryFlipped
        return own
    }

    private static func copyTree(_ model: CALayer, scale: CGFloat, budget: Budget) -> CALayer? {
        // Invisible retained trees contribute no pixels. Skip before geometry
        // checks/allocation so their stale bounds cannot reject a visible frame.
        if isInvisible(model) || isDecorativeSheetShadow(model) {
            let empty = CALayer()
            empty.isHidden = true
            return empty
        }
        let source = model.presentation() ?? model
        // Unknown geometry is omitted rather than risking a misplaced exclusion.
        guard CATransform3DIsAffine(source.transform),
              CATransform3DIsAffine(source.sublayerTransform),
              source.bounds.width.isFinite, source.bounds.height.isFinite,
              source.bounds.width >= 0, source.bounds.height >= 0,
              budget.admit(.zero, scale: scale) else { return nil }
        // init(layer:) is reserved for Core Animation presentation copies.
        // Build ordinary detached layers using their documented properties.
        let shell = CALayer()
        shell.bounds = source.bounds
        shell.position = source.position
        shell.anchorPoint = source.anchorPoint
        shell.transform = source.transform
        shell.sublayerTransform = source.sublayerTransform
        shell.zPosition = source.zPosition
        shell.opacity = source.opacity
        shell.isHidden = source.isHidden
        shell.isGeometryFlipped = source.isGeometryFlipped
        shell.masksToBounds = source.masksToBounds
        shell.cornerRadius = source.cornerRadius
        shell.maskedCorners = source.maskedCorners
        shell.cornerCurve = source.cornerCurve
        shell.actions = [:]
        if scale == 1 {
            shell.minificationFilter = .nearest
            shell.magnificationFilter = .nearest
        }

        if isExcluded(model) {
            shell.backgroundColor = UIColor.black.cgColor
            return shell
        }
        // Preserve clipping masks, which are independent of the content subtree.
        if let mask = model.mask {
            guard let copiedMask = copyTree(mask, scale: scale, budget: budget) else { return nil }
            shell.mask = copiedMask
        }
        // Plain container layers have no own drawing. Avoid allocating a full
        // screen bitmap for every empty ancestor of the viewport and controls.
        // A backdrop can cache pixels sampled from the live stream. Never copy
        // those pixels into replay; its foreground control children still draw.
        let typeName = String(describing: type(of: source))
        let isBackdrop = ["Backdrop", "Glass", "Filter"].contains(where: typeName.contains)
        let hasOwnDrawing = !isBackdrop && (source.contents != nil
            || (source.backgroundColor?.alpha ?? 0) > 0
            || source.borderWidth > 0
            || !(type(of: source) == CALayer.self || source is CATransformLayer || source.delegate is UIWindow))
        if !source.isHidden && source.opacity > 0 && !source.bounds.isEmpty && hasOwnDrawing {
            // Plain drawing already has detached, documented properties. Reuse its
            // image reference instead of allocating and rasterizing a screen-sized
            // bitmap for every ancestor. Excluded and backdrop layers returned or
            // were rejected above, before their contents can reach this branch.
            if type(of: source) == CALayer.self || (source.contents != nil
                && !(source is CAShapeLayer || source is CATextLayer || source is CAGradientLayer)) {
                shell.contents = source.contents
                shell.contentsScale = source.contentsScale
                shell.contentsRect = source.contentsRect
                shell.contentsCenter = source.contentsCenter
                shell.contentsGravity = source.contentsGravity
                shell.backgroundColor = source.backgroundColor
                shell.borderWidth = source.borderWidth
                shell.borderColor = source.borderColor
            } else {
                guard budget.admit(source.bounds.size, scale: scale) else { return nil }
                guard let image = PostHogGraphicsImageRenderer(size: source.bounds.size, scale: scale).image(actions: { context in
                    if let own = ownDrawingLayer(source) {
                        own.render(in: context)
                    } else if model.sublayers?.isEmpty != false && model.mask == nil {
                        // A childless native layer cannot bring an excluded subtree
                        // into the image. Read it without altering its properties.
                        source.render(in: context)
                    } else {
                        // draw(in:) and the delegate's draw callback provide the
                        // layer's own drawing, without traversing its sublayers.
                        context.translateBy(x: -source.bounds.minX, y: -source.bounds.minY)
                        if let delegate = source.delegate,
                           delegate.responds(to: #selector(CALayerDelegate.draw(_:in:))) {
                            delegate.draw?(source, in: context)
                        } else {
                            source.draw(in: context)
                        }
                    }
                }), let cgImage = image.cgImage else { return nil }
                // Own drawing belongs to the parent, not a child: applying the
                // parent's sublayerTransform to it would move controls incorrectly.
                shell.contents = cgImage
                shell.contentsScale = scale
                shell.contentsGravity = .resize
                shell.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                shell.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }
        // CALayer z ordering is preserved by each copied child's zPosition; order
        // remains stable for ties. SwiftUI controls are siblings of the stream.
        for child in model.sublayers ?? [] {
            guard let copied = copyTree(child, scale: scale, budget: budget) else { return nil }
            shell.addSublayer(copied)
        }
        return shell
    }
}
#endif
