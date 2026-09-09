import CoreGraphics

/// Converts an element's untransformed content rectangle into viewport coordinates.
///
/// Selection overlays and other editor affordances should use this same geometry
/// instead of independently estimating an element's size.
public enum ElementFrameGeometry {
    public static func frame(
        contentSize: CGSize,
        transform: ElementTransform,
        contentRect: CGRect,
        viewportScale: CGFloat,
        viewportOffset: CGPoint
    ) -> CGRect {
        let scale = max(viewportScale.isFinite ? viewportScale : 1, 0)
        let width = max(contentSize.width.isFinite ? contentSize.width : 0, 0)
        let height = max(contentSize.height.isFinite ? contentSize.height : 0, 0)
        let elementScale = max(transform.scale.isFinite ? transform.scale : 0, 0)
        let center = CGPoint(
            x: viewportOffset.x + (transform.position.x - contentRect.minX) * scale,
            y: viewportOffset.y + (contentRect.maxY - transform.position.y) * scale
        )
        return CGRect(
            x: center.x - width * elementScale * scale / 2,
            y: center.y - height * elementScale * scale / 2,
            width: width * elementScale * scale,
            height: height * elementScale * scale
        )
    }
}
