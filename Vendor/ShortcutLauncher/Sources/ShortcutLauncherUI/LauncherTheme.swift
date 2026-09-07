import SwiftUI

/// Host-neutral visual configuration for the launcher surface.
///
/// Embedding products can provide a theme through the environment without
/// changing Core behavior or copying the HostDemo views.
public struct LauncherTheme: @unchecked Sendable {
  public var title: String
  public var subtitle: String
  /// When non-nil, the embedding host owns appearance and the user preference
  /// remains stored but does not override the host surface.
  public var lockedAppearance: LauncherAppearance?
  public var panelTint: LinearGradient
  public var cardFill: Color
  public var emptyCardFill: Color
  public var cardBorder: Color
  public var focusColor: Color
  public var successColor: Color
  public var warningColor: Color
  public var errorColor: Color
  public var panelPadding: CGFloat
  public var sectionSpacing: CGFloat
  public var cornerRadius: CGFloat
  public var motionDuration: Double

  public init(
    title: String = "快捷启动",
    subtitle: String = "选择键位，绑定你想打开的目标",
    lockedAppearance: LauncherAppearance? = nil,
    panelTint: LinearGradient = LinearGradient(
      colors: [
        Color.accentColor.opacity(0.08),
        Color.clear,
        Color.cyan.opacity(0.035),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    ),
    cardFill: Color = Color.primary.opacity(0.075),
    emptyCardFill: Color = Color.primary.opacity(0.035),
    cardBorder: Color = Color.primary.opacity(0.13),
    focusColor: Color = .accentColor,
    successColor: Color = .green,
    warningColor: Color = .orange,
    errorColor: Color = .red,
    panelPadding: CGFloat = 24,
    sectionSpacing: CGFloat = 18,
    cornerRadius: CGFloat = 16,
    motionDuration: Double = 0.16
  ) {
    self.title = title
    self.subtitle = subtitle
    self.lockedAppearance = lockedAppearance
    self.panelTint = panelTint
    self.cardFill = cardFill
    self.emptyCardFill = emptyCardFill
    self.cardBorder = cardBorder
    self.focusColor = focusColor
    self.successColor = successColor
    self.warningColor = warningColor
    self.errorColor = errorColor
    self.panelPadding = panelPadding
    self.sectionSpacing = sectionSpacing
    self.cornerRadius = cornerRadius
    self.motionDuration = motionDuration
  }

  public static let standard = LauncherTheme()
}

private struct LauncherThemeEnvironmentKey: EnvironmentKey {
  static let defaultValue = LauncherTheme.standard
}

extension EnvironmentValues {
  public var launcherTheme: LauncherTheme {
    get { self[LauncherThemeEnvironmentKey.self] }
    set { self[LauncherThemeEnvironmentKey.self] = newValue }
  }
}

extension View {
  public func launcherTheme(_ theme: LauncherTheme) -> some View {
    environment(\.launcherTheme, theme)
  }
}
