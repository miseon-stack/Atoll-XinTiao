import CoreGraphics

/// Deterministic sizing for the four-row physical-keyboard presentation.
/// Keeping the calculation outside SwiftUI makes responsive behavior testable.
public struct KeyboardLayoutMetrics: Equatable, Sendable {
  public enum Density: String, Equatable, Sendable {
    case regular
    case compact
    case dense
    case scrollingFallback
  }

  public let density: Density
  public let keyWidth: CGFloat
  public let keyHeight: CGFloat
  public let horizontalSpacing: CGFloat
  public let verticalSpacing: CGFloat
  public let rowIndent: CGFloat
  public let contentWidth: CGFloat
  public let usesHorizontalScrolling: Bool

  public static func resolve(availableWidth: CGFloat) -> KeyboardLayoutMetrics {
    let width = max(0, availableWidth)
    let values: (
      density: Density,
      keyWidth: CGFloat,
      keyHeight: CGFloat,
      spacing: CGFloat,
      rowIndent: CGFloat,
      scroll: Bool
    )

    switch width {
    case 1020...:
      values = (.regular, 72, 88, 10, 18, false)
    case 810..<1020:
      values = (.compact, 58, 76, 8, 15, false)
    case 680..<810:
      values = (.dense, 50, 68, 6, 12, false)
    default:
      values = (.scrollingFallback, 50, 68, 6, 12, true)
    }

    // The widest row contains twelve keys. A small trailing allowance keeps
    // focus rings and shadows from being clipped at the viewport edge.
    let contentWidth = (12 * values.keyWidth) + (11 * values.spacing) + 8
    return KeyboardLayoutMetrics(
      density: values.density,
      keyWidth: values.keyWidth,
      keyHeight: values.keyHeight,
      horizontalSpacing: values.spacing,
      verticalSpacing: max(6, values.spacing + 2),
      rowIndent: values.rowIndent,
      contentWidth: contentWidth,
      usesHorizontalScrolling: values.scroll
    )
  }
}
