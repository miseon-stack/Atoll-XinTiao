import CoreGraphics

/// Platform-independent panel placement calculations.
///
/// AppKit callers can pass `NSSize` and `NSRect` directly because they bridge to
/// `CGSize` and `CGRect`. Keeping this calculation in Core makes multi-display
/// behavior deterministic and testable without creating a window.
public enum PanelGeometry {
  /// Centers a preferred panel size inside a display's visible frame.
  ///
  /// The result is inset by `margin` where the display has enough room. A panel
  /// larger than the available area is reduced independently on each axis. A
  /// negative or non-finite margin is treated as zero; a non-finite preferred
  /// dimension fills the available dimension.
  public static func frame(
    preferredSize: CGSize,
    inside visibleFrame: CGRect,
    margin: CGFloat = 0
  ) -> CGRect {
    let container = visibleFrame.standardized
    let requestedMargin = margin.isFinite ? max(0, margin) : 0
    let horizontalMargin = min(requestedMargin, container.width / 2)
    let verticalMargin = min(requestedMargin, container.height / 2)
    let availableFrame = CGRect(
      x: container.minX + horizontalMargin,
      y: container.minY + verticalMargin,
      width: max(0, container.width - horizontalMargin * 2),
      height: max(0, container.height - verticalMargin * 2)
    )

    let width = clamped(preferredSize.width, maximum: availableFrame.width)
    let height = clamped(preferredSize.height, maximum: availableFrame.height)

    return CGRect(
      x: availableFrame.midX - width / 2,
      y: availableFrame.midY - height / 2,
      width: width,
      height: height
    )
  }

  private static func clamped(_ preferred: CGFloat, maximum: CGFloat) -> CGFloat {
    guard preferred.isFinite else { return maximum }
    return min(max(0, preferred), maximum)
  }
}
