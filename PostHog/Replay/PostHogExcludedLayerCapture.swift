#if os(iOS)
import UIKit
import ObjectiveC

private var replayExclusionKey: UInt8 = 0

public extension UIView {
    /// Removes this view's drawing subtree from replay screenshots while preserving
    /// siblings drawn above it. Unlike a rectangular mask, overlapping controls remain.
    /// Set on the native content view, never on the container holding its controls.
    @objc var postHogExcludeFromReplay: Bool {
        get { (objc_getAssociatedObject(layer, &replayExclusionKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(layer, &replayExclusionKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// Detached capture: no live view/layer is hidden, reparented, or modified. Native
/// stream layers are replaced before any rendering, so their pixels never enter
/// the replay image. Ordinary descendants and overlapping siblings are retained.
/// Full-tree layer rendering previously hung on SwiftUI effects. Rasterize only
/// one childless layer at a time, then composite plain bitmap layers instead.
enum PostHogExcludedLayerCapture {
    static func containsExclusion(_ layer: CALayer) -> Bool {
        if isExcluded(layer) { return true }
        return layer.sublayers?.contains(where: containsExclusion) ?? false
    }

    private static func isExcluded(_ layer: CALayer) -> Bool {
        (objc_getAssociatedObject(layer, &replayExclusionKey) as? Bool) ?? false
    }

    static func image(of view: UIView) -> UIImage? {
        // A background screenshot must never fall back to unfiltered capture.
        guard Thread.isMainThread else { return nil }
        let scale = (view as? UIWindow ?? view.window)?.screen.scale ?? 1
        let budget = Budget(pixelLimit: view.bounds.width * view.bounds.height * scale * scale * 12)
        guard let tree = copyTree(view.layer, scale: scale, budget: budget) else { return nil }
        return PostHogGraphicsImageRenderer(size: view.bounds.size, scale: scale).image { context in
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

    private static func copyTree(_ model: CALayer, scale: CGFloat, budget: Budget) -> CALayer? {
        let source = model.presentation() ?? model
        // Unknown geometry is omitted rather than risking a misplaced exclusion.
        guard CATransform3DIsAffine(source.transform),
              CATransform3DIsAffine(source.sublayerTransform),
              source.bounds.width.isFinite, source.bounds.height.isFinite,
              source.bounds.width >= 0, source.bounds.height >= 0,
              budget.admit(.zero, scale: scale) else { return nil }
        let shell = CALayer(layer: source)
        shell.delegate = nil
        shell.sublayers = nil
        shell.mask = nil
        shell.contents = nil
        shell.backgroundColor = nil
        shell.borderWidth = 0
        shell.shadowOpacity = 0
        shell.filters = nil
        shell.compositingFilter = nil
        shell.shouldRasterize = false
        shell.actions = [:]

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
        let isBackdrop = String(describing: type(of: source)).contains("Backdrop")
        let hasOwnDrawing = !isBackdrop && (source.contents != nil
            || (source.backgroundColor?.alpha ?? 0) > 0
            || source.borderWidth > 0
            || !(type(of: source) == CALayer.self || source is CATransformLayer || source.delegate is UIWindow))
        if !source.isHidden && source.opacity > 0 && !source.bounds.isEmpty && hasOwnDrawing {
            guard budget.admit(source.bounds.size, scale: scale) else { return nil }
            let own = type(of: source).init(layer: source)
            own.sublayers = nil
            own.mask = nil
            own.opacity = 1
            own.shadowOpacity = 0
            own.filters = nil
            own.compositingFilter = nil
            own.shouldRasterize = false
            guard let image = PostHogGraphicsImageRenderer(size: source.bounds.size, scale: scale).image(actions: { context in
                own.render(in: context)
            }), let cgImage = image.cgImage else { return nil }
            // Own drawing belongs to the parent, not a child: applying the
            // parent's sublayerTransform to it would move controls incorrectly.
            shell.contents = cgImage
            shell.contentsScale = scale
            shell.contentsGravity = .resize
            shell.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            shell.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
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
