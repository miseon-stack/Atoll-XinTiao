import AppKit
import ShortcutLauncherCore
import SwiftUI

struct LauncherKeyCard: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.launcherTheme) private var theme

  let slot: KeySlotDefinition
  let presentation: BindingPresentation
  let bindingID: BindingID?
  let target: LaunchTarget?
  let websiteIconProvider: any WebsiteIconProviding
  let metrics: KeyboardLayoutMetrics
  let isBusy: Bool
  let isKeyboardFocused: Bool
  let isDropTarget: Bool
  let showsSuccess: Bool
  let action: () -> Void
  let replaceAction: () -> Void
  let advancedAction: () -> Void
  let removeAction: () -> Void
  let refreshWebsiteIconAction: (() -> Void)?
  let chooseWebsiteIconAction: (() -> Void)?
  let restoreWebsiteIconAction: (() -> Void)?

  @State private var isHovered = false
  @State private var isPressed = false

  private var isBound: Bool {
    presentation.bindingID != nil && presentation.displayName != nil
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button {
        guard !isBusy else { return }
        action()
      } label: {
        cardContent
      }
      .buttonStyle(LauncherCardButtonStyle(isPressed: $isPressed))
      .disabled(isBusy)

      if isBound && (isHovered || isKeyboardFocused) && !isBusy {
        managementMenu
          .padding(6)
          .transition(.opacity)
      }
    }
    .frame(width: metrics.keyWidth, height: metrics.keyHeight)
    .contentShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
    .background(cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .stroke(borderColor, lineWidth: borderWidth)
    }
    .overlay(alignment: .topTrailing) {
      if isKeyboardFocused {
        Circle()
          .fill(theme.focusColor)
          .frame(
            width: colorSchemeContrast == .increased ? 10 : 8,
            height: colorSchemeContrast == .increased ? 10 : 8
          )
          .overlay {
            Circle()
              .stroke(.background.opacity(0.9), lineWidth: 1.5)
          }
          .shadow(color: theme.focusColor.opacity(0.35), radius: 2)
          .offset(x: 2, y: -2)
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .topLeading) {
      if isBound {
        Text(presentation.panelKeyLabel)
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.thinMaterial, in: Capsule())
          .padding(6)
      }
    }
    .overlay(alignment: .bottom) {
      if isDropTarget {
        Label("释放到此键位", systemImage: "arrow.down.circle.fill")
          .font(.system(size: 9, weight: .semibold))
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(.regularMaterial, in: Capsule())
          .padding(.bottom, 5)
          .accessibilityLabel("可以释放到键位 \(presentation.panelKeyLabel)")
      }
    }
    .shadow(
      color: .black.opacity(isHovered || isKeyboardFocused ? 0.13 : (isBound ? 0.07 : 0.025)),
      radius: isHovered || isKeyboardFocused ? 10 : 6,
      y: isHovered || isKeyboardFocused ? 5 : 3
    )
    .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.975 : (showsSuccess ? 1.025 : 1)))
    .animation(
      reduceMotion ? nil : .easeOut(duration: theme.motionDuration),
      value: isHovered
    )
    .animation(
      reduceMotion ? nil : .easeOut(duration: theme.motionDuration),
      value: showsSuccess
    )
    .onHover { isHovered = $0 }
    .help(helpText)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("launcher.slot.\(slot.keyCode)")
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(isBound ? "打开目标；使用更多按钮或右键管理" : "添加一个快捷启动目标")
    .accessibilityAction(named: "更换目标") { replaceAction() }
    .accessibilityAction(named: "快捷键设置") { advancedAction() }
    .accessibilityAction(named: "移除绑定") {
      if isBound { removeAction() }
    }
    .accessibilityAction(named: "刷新网站图标") {
      refreshWebsiteIconAction?()
    }
  }

  @ViewBuilder
  private var cardContent: some View {
    if isBusy {
      VStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("正在保存")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if isBound {
      VStack(spacing: metrics.density == .regular ? 7 : 5) {
        Spacer(minLength: 4)
        icon
          .frame(
            width: metrics.density == .regular ? 38 : 32,
            height: metrics.density == .regular ? 38 : 32
          )

        Text(presentation.displayName ?? target?.displayName ?? "目标")
          .font(.system(size: metrics.density == .regular ? 12 : 11, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.horizontal, 5)

        if let issueLabel {
          Label(issueLabel.text, systemImage: issueLabel.symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(issueLabel.color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        Spacer(minLength: 3)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 5) {
        Text(presentation.panelKeyLabel)
          .font(.system(size: metrics.density == .regular ? 24 : 20, weight: .bold, design: .rounded))
          .foregroundStyle(.primary.opacity(0.9))
        Image(systemName: "plus")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.secondary)
          .opacity(isHovered || isKeyboardFocused ? 1 : 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var icon: some View {
    if let target {
      if target.kind == .web {
        if let bindingID {
          WebsiteBindingIcon(
            bindingID: bindingID,
            websiteURL: target.lastKnownURL,
            provider: websiteIconProvider,
            size: metrics.density == .regular ? 38 : 32
          )
        } else {
          DeterministicWebsiteMonogram(url: target.lastKnownURL)
        }
      } else {
        Image(nsImage: LauncherIconCache.shared.icon(for: target.lastKnownURL))
          .resizable()
          .scaledToFit()
      }
    } else {
      Image(systemName: "plus")
        .foregroundStyle(.secondary)
    }
  }

  private var managementMenu: some View {
    Menu {
      Button("更换目标…", action: replaceAction)
      Button("快捷键设置…", action: advancedAction)
      if target?.kind == .web {
        Divider()
        if let refreshWebsiteIconAction {
          Button("刷新网站图标", action: refreshWebsiteIconAction)
        }
        if let chooseWebsiteIconAction {
          Button("选择自定义图标…", action: chooseWebsiteIconAction)
        }
        if let restoreWebsiteIconAction {
          Button("恢复网站图标", action: restoreWebsiteIconAction)
        }
      }
      Divider()
      Button("移除绑定", role: .destructive, action: removeAction)
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 11, weight: .bold))
        .frame(width: 24, height: 20)
        .background(.regularMaterial, in: Capsule())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("管理 \(presentation.displayName ?? "目标")")
    .accessibilityIdentifier("launcher.slot.\(slot.keyCode).manage")
    .accessibilityLabel("管理 \(presentation.displayName ?? "目标")")
  }

  private var cardBackground: some ShapeStyle {
    if isDropTarget {
      return AnyShapeStyle(theme.focusColor.opacity(0.18))
    }
    if showsSuccess {
      return AnyShapeStyle(theme.successColor.opacity(0.16))
    }
    return AnyShapeStyle(isBound ? theme.cardFill : theme.emptyCardFill)
  }

  private var borderColor: Color {
    if isDropTarget { return theme.focusColor.opacity(0.9) }
    if showsSuccess { return theme.successColor.opacity(0.9) }
    switch presentation.runtimeState {
    case .conflicted, .paused:
      return theme.warningColor.opacity(0.82)
    case .targetUnavailable:
      return theme.errorColor.opacity(0.9)
    default:
      return theme.cardBorder
    }
  }

  private var borderWidth: CGFloat {
    if isDropTarget || showsSuccess {
      return colorSchemeContrast == .increased ? 3 : 2
    }
    switch presentation.runtimeState {
    case .conflicted, .targetUnavailable:
      return colorSchemeContrast == .increased ? 2.5 : 1.5
    default:
      return colorSchemeContrast == .increased ? 2 : 1
    }
  }

  private var issueLabel: (text: String, symbol: String, color: Color)? {
    switch presentation.runtimeState {
    case .paused:
      return ("已暂停", "pause.circle.fill", theme.warningColor)
    case .conflicted:
      return ("快捷键冲突", "exclamationmark.triangle.fill", theme.warningColor)
    case .targetUnavailable:
      return ("目标不可用", "questionmark.folder.fill", theme.errorColor)
    default:
      return nil
    }
  }

  private var helpText: String {
    guard let name = presentation.displayName else {
      return "键位 \(presentation.panelKeyLabel)：点击添加"
    }
    let shortcut = presentation.directHotkeyLabel.map { "，全局快捷键 \($0)" } ?? ""
    return "键位 \(presentation.panelKeyLabel)：点击打开 \(name)\(shortcut)；更多按钮或右键可管理"
  }

  private var accessibilityLabel: String {
    guard let name = presentation.displayName else {
      return "键位 \(presentation.panelKeyLabel)，未绑定"
    }
    let state = issueLabel.map { "，\($0.text)" } ?? ""
    return "键位 \(presentation.panelKeyLabel)，\(name)\(state)"
  }

  private var accessibilityValue: String {
    guard isBound else { return "未绑定" }
    let kind = presentation.targetKind?.displayName ?? "目标"
    let shortcut = presentation.directHotkeyLabel.map { "全局快捷键 \($0)" } ?? "仅面板"
    let icon = target?.kind == .web ? "网站图标可刷新" : "本地图标"
    return "\(kind)，\(shortcut)，\(icon)"
  }
}

struct DeterministicWebsiteMonogram: View {
  let url: URL

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(background.gradient)
      Text(initial)
        .font(.title3.bold())
        .foregroundStyle(.white)
    }
    .accessibilityHidden(true)
  }

  private var initial: String {
    String((url.host ?? "W").prefix(1)).uppercased()
  }

  private var background: Color {
    let palette: [Color] = [.blue, .indigo, .purple, .pink, .teal, .cyan, .orange]
    let scalarSum = (url.host ?? "web").unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return palette[abs(scalarSum) % palette.count]
  }
}

private struct LauncherCardButtonStyle: ButtonStyle {
  @Binding var isPressed: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .onChange(of: configuration.isPressed) { _, newValue in
        isPressed = newValue
      }
  }
}
