import SwiftUI

/// A small, host-neutral visual vocabulary for the launcher surface.
/// Keeping these values together makes the package easy to retheme when it is
/// embedded in another product without coupling Core behavior to one brand.
enum LauncherVisualTokens {
  static let panelPadding: CGFloat = 24
  static let sectionSpacing: CGFloat = 20
  static let rowSpacing: CGFloat = 12
  static let keySpacing: CGFloat = 10
  static let keyWidth: CGFloat = 72
  static let keyHeight: CGFloat = 88
  static let keyCornerRadius: CGFloat = 16
  static let popoverWidth: CGFloat = 356

  static let panelTint = LinearGradient(
    colors: [
      Color.accentColor.opacity(0.08),
      Color.clear,
      Color.cyan.opacity(0.035),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
}
