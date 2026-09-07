import ShortcutLauncherCore
import SwiftUI

struct LauncherSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var module: ShortcutLauncherModule

  @State private var panelHotkeyCandidate: HotkeyDefinition?
  @State private var panelHotkeyBaseline: HotkeyDefinition
  @State private var recorderSessionID = UUID()
  @State private var recorderFocusRequestID: UInt64 = 0
  @State private var recorderState: HotkeyRecorderState
  @State private var pendingDirectEnabled: Bool?
  @State private var pendingAppearance: LauncherAppearance?
  @State private var pendingOnlineIconsEnabled: Bool?
  @State private var websiteIconMaintenance: WebsiteIconMaintenance?
  @State private var localMessage: SettingsMessage?
  @State private var isViewPresented = false

  init(module: ShortcutLauncherModule) {
    self.module = module
    _panelHotkeyCandidate = State(initialValue: module.currentConfiguration.panelHotkey)
    _panelHotkeyBaseline = State(initialValue: module.currentConfiguration.panelHotkey)
    _recorderState = State(
      initialValue: HotkeyRecorderState(value: module.currentConfiguration.panelHotkey)
    )
  }

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 20) {
        header
        panelHotkeySection
        globalHotkeySection
        websiteIconSection
        appearanceSection
        dataAndAdvancedSection
        feedback
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 440, idealWidth: 660, minHeight: 420, idealHeight: 680)
    .accessibilityIdentifier("launcher.settings")
    .onAppear { isViewPresented = true }
    .onDisappear {
      isViewPresented = false
      Task { await module.endHotkeyRecorderSession(recorderSessionID) }
    }
    .onChange(of: module.configurationRevision) { _, _ in
      synchronizeCommittedSettingsIfAppropriate()
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("快捷启动设置")
          .font(.title2.bold())
        Text("更改会保存到当前快捷启动模块，不会创建批量编辑草稿。")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("完成") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("launcher.settings.done")
        .accessibilityHint("关闭设置并返回快捷启动面板")
    }
  }

  private var panelHotkeySection: some View {
    GroupBox("基础设置") {
      VStack(alignment: .leading, spacing: 12) {
        Text("面板唤出快捷键")
          .font(.subheadline.weight(.semibold))

        HotkeyRecorderView(
          hotkey: $panelHotkeyCandidate,
          labelSnapshot: module.keyLabelSnapshot,
          accessibilityIdentifier: "launcher.settings.panelRecorder",
          focusRequestID: recorderFocusRequestID,
          onActivationRequest: {
            guard isViewPresented, !module.isCommitting else { return false }
            let isReady = await module.beginHotkeyRecorderSession(recorderSessionID)
            guard isViewPresented, isReady, !module.isCommitting else {
              await module.endHotkeyRecorderSession(recorderSessionID)
              return false
            }
            return true
          },
          onDeactivation: {
            await module.endHotkeyRecorderSession(recorderSessionID)
          },
          onStateChange: { recorderState = $0 }
        )
        .disabled(module.isCommitting || pendingDirectEnabled != nil)
        .frame(maxWidth: .infinity, minHeight: 44)

        if let panelHotkeyCandidate {
          Text("候选：\(module.hotkeyDisplayName(panelHotkeyCandidate))")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }

        if let panelValidationMessage {
          Label(panelValidationMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          Text("点击录制框后按下组合键；只有系统注册与保存都成功，旧组合才会被替换。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          Spacer()
          Button(module.isCommitting ? "正在应用…" : "应用面板快捷键") {
            applyPanelHotkey()
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("launcher.settings.save")
          .accessibilityHint("只验证并保存面板唤出快捷键")
          .disabled(!canApplyPanelHotkey)
        }
      }
      .padding(.vertical, 6)
    }
  }

  private var globalHotkeySection: some View {
    GroupBox("全局快捷键") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("启用全局快捷键", isOn: directEnabledBinding)
          .accessibilityIdentifier("launcher.settings.directEnabled")
          .accessibilityHint("关闭后仍可从面板打开已绑定目标")
          .disabled(module.isCommitting || pendingDirectEnabled != nil || module.isEditing)

        Label(directRuntimeText, systemImage: directRuntimeSystemImage)
          .font(.caption)
          .foregroundStyle(directRuntimeColor)

        Text(module.directShortcutSummary)
          .font(.caption)
          .foregroundStyle(.secondary)

        Text("此开关只控制已保存的全局组合；面板、绑定和目标不会被删除。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 6)
    }
  }

  private var websiteIconSection: some View {
    GroupBox("网站图标与隐私") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("在线获取网站图标", isOn: onlineIconsBinding)
          .accessibilityIdentifier("launcher.settings.websiteIcons")
          .accessibilityHint("关闭后不再为网站发起新的图标请求")
          .disabled(module.isSavingUIPreferences || pendingOnlineIconsEnabled != nil)

        Text("开启后，仅在绑定网站或你主动刷新时访问该网站及其明确声明的图标资源。不会携带 Cookie、登录态或完整页面路径。")
          .font(.caption)
          .foregroundStyle(.secondary)

        Text("关闭在线获取不会影响网站绑定和打开；已有缓存图标仍可显示。")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 10) {
          Button(
            websiteIconMaintenance == .backfill
              ? "正在获取…" : "为已有网站获取图标（\(existingWebsiteCount)）"
          ) {
            performWebsiteIconMaintenance(.backfill)
          }
          .accessibilityIdentifier("launcher.settings.websiteIcons.backfill")
          .accessibilityHint("仅这一次检查当前已绑定网站的图标")
          .disabled(
            !module.canManageWebsiteIcons
              || !module.uiPreferences.onlineWebsiteIconsEnabled
              || existingWebsiteCount == 0
              || websiteIconMaintenance != nil
          )

          Button(websiteIconMaintenance == .clearCache ? "正在清理…" : "清理自动缓存") {
            performWebsiteIconMaintenance(.clearCache)
          }
          .accessibilityIdentifier("launcher.settings.websiteIcons.clearCache")
          .accessibilityHint("清除可重新获取的自动图标，不删除自定义网站图标")
          .disabled(!module.canManageWebsiteIcons || websiteIconMaintenance != nil)
        }
      }
      .padding(.vertical, 6)
    }
  }

  private var appearanceSection: some View {
    GroupBox("外观") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("外观", selection: appearanceBinding) {
          ForEach(LauncherAppearance.allCases, id: \.self) { appearance in
            Text(appearance.displayName).tag(appearance)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("launcher.settings.appearance")
        .accessibilityLabel("快捷启动外观")
        .disabled(
          module.launcherTheme.lockedAppearance != nil
            || module.isSavingUIPreferences
            || pendingAppearance != nil
        )

        Text(
          module.launcherTheme.lockedAppearance == nil
            ? "“跟随宿主或系统”会采用当前产品或 macOS 的外观设置。"
            : "当前外观由宿主产品统一设置。"
        )
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 6)
    }
  }

  private var dataAndAdvancedSection: some View {
    GroupBox("数据与高级") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Button("导出当前配置…") { module.exportConfiguration() }
            .accessibilityIdentifier("launcher.settings.export")
            .accessibilityHint("把当前配置导出到你选择的本地文件")

          Button("导入并预览…") {
            Task {
              await module.endHotkeyRecorderSession(recorderSessionID)
              await module.importConfiguration()
              dismiss()
            }
          }
          .accessibilityIdentifier("launcher.settings.import")
          .accessibilityHint("选择本地配置文件，预览确认后再应用")
          .disabled(module.isCommitting)

          Spacer()

          Text("导入前会备份当前有效配置")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Divider()

        HStack(spacing: 10) {
          Button("批量整理键位…") {
            Task {
              await module.endHotkeyRecorderSession(recorderSessionID)
              module.beginEditing()
              dismiss()
            }
          }
          .accessibilityIdentifier("launcher.settings.batch")
          .accessibilityHint("明确进入批量模式并创建一次可取消的编辑草稿")
          .disabled(module.isCommitting || module.isEditing)

          Button(
            module.uiPreferences.shouldShowOnboarding ? "使用提示已显示" : "再次显示使用提示"
          ) {
            showOnboardingAgain()
          }
          .accessibilityIdentifier("launcher.settings.onboarding")
          .accessibilityHint("在主面板重新显示非阻断的入门提示")
          .disabled(
            module.uiPreferences.shouldShowOnboarding
              || module.isSavingUIPreferences
          )
        }

        Text("只有点击“批量整理键位”才会创建批量草稿；查看设置、导入预览和调整外观都不会进入批量模式。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 6)
    }
  }

  @ViewBuilder
  private var feedback: some View {
    if let localMessage {
      Label(localMessage.text, systemImage: localMessage.systemImage)
        .font(.caption)
        .foregroundStyle(localMessage.isError ? Color.red : Color.secondary)
        .textSelection(.enabled)
        .accessibilityIdentifier("launcher.settings.feedback")
    } else if let errorMessage = module.errorMessage {
      Label(errorMessage, systemImage: "xmark.octagon.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
    }
  }

  private var panelValidationMessage: String? {
    guard let panelHotkeyCandidate else {
      return "面板唤出快捷键不能为空，请重新录制一个组合键。"
    }
    do {
      try panelHotkeyCandidate.validate()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private var canApplyPanelHotkey: Bool {
    guard let panelHotkeyCandidate else { return false }
    return panelValidationMessage == nil
      && panelHotkeyCandidate != module.currentConfiguration.panelHotkey
      && !module.isCommitting
      && pendingDirectEnabled == nil
      && !module.isEditing
  }

  private var directEnabledBinding: Binding<Bool> {
    Binding(
      get: { pendingDirectEnabled ?? module.currentConfiguration.directModeEnabled },
      set: { enabled in
        guard pendingDirectEnabled == nil else { return }
        pendingDirectEnabled = enabled
        localMessage = nil
        Task {
          await module.endHotkeyRecorderSession(recorderSessionID)
          let result = await module.applyLauncherSettings(
            panelHotkey: module.currentConfiguration.panelHotkey,
            directModeEnabled: enabled
          )
          pendingDirectEnabled = nil
          localMessage = SettingsMessage(result: result, operation: "全局快捷键设置")
        }
      }
    )
  }

  private var appearanceBinding: Binding<LauncherAppearance> {
    Binding(
      get: { pendingAppearance ?? module.uiPreferences.appearance },
      set: { appearance in
        guard pendingAppearance == nil else { return }
        pendingAppearance = appearance
        localMessage = nil
        Task {
          let saved = await module.setAppearance(appearance)
          pendingAppearance = nil
          if !saved {
            localMessage = .failure("外观设置未能保存，已保留原来的选择。")
          }
        }
      }
    )
  }

  private var onlineIconsBinding: Binding<Bool> {
    Binding(
      get: {
        pendingOnlineIconsEnabled ?? module.uiPreferences.onlineWebsiteIconsEnabled
      },
      set: { enabled in
        guard pendingOnlineIconsEnabled == nil else { return }
        pendingOnlineIconsEnabled = enabled
        localMessage = nil
        Task {
          let saved = await module.setOnlineWebsiteIconsEnabled(enabled)
          pendingOnlineIconsEnabled = nil
          if !saved {
            localMessage = .failure("网站图标设置未能保存，已保留原来的选择。")
          }
        }
      }
    )
  }

  private var directRuntimeText: String {
    if let pendingDirectEnabled {
      return pendingDirectEnabled ? "正在启用全局快捷键…" : "正在关闭全局快捷键…"
    }
    guard module.currentConfiguration.directModeEnabled else {
      return "全局快捷键已关闭；面板内打开仍可使用"
    }
    let conflictCount = module.bindingPresentations.filter {
      if case .conflicted = $0.runtimeState { return true }
      return false
    }.count
    if conflictCount > 0 {
      return "已启用，但有 \(conflictCount) 个组合被系统或其他软件占用"
    }
    if recorderState.isFocused || module.isHotkeyRecorderReady {
      return module.isHotkeyRecorderReady
        ? "录制期间已临时让出全局组合；完成后自动恢复"
        : "正在准备安全录制"
    }
    return "可用的全局快捷键已启用"
  }

  private var existingWebsiteCount: Int {
    module.currentConfiguration.bindings.values.filter { $0.target.kind == .web }.count
  }

  private var directRuntimeSystemImage: String {
    if pendingDirectEnabled != nil { return "arrow.triangle.2.circlepath" }
    if !module.currentConfiguration.directModeEnabled { return "pause.circle" }
    return module.bindingPresentations.contains(where: {
      if case .conflicted = $0.runtimeState { return true }
      return false
    }) ? "exclamationmark.triangle" : "checkmark.circle"
  }

  private var directRuntimeColor: Color {
    directRuntimeSystemImage == "exclamationmark.triangle" ? .orange : .secondary
  }

  private func applyPanelHotkey() {
    guard panelValidationMessage == nil, let panelHotkeyCandidate else { return }
    localMessage = nil
    Task {
      await module.endHotkeyRecorderSession(recorderSessionID)
      let result = await module.applyLauncherSettings(
        panelHotkey: panelHotkeyCandidate,
        directModeEnabled: module.currentConfiguration.directModeEnabled
      )
      localMessage = SettingsMessage(result: result, operation: "面板快捷键")
      if case .committed = result {
        self.panelHotkeyCandidate = module.currentConfiguration.panelHotkey
        panelHotkeyBaseline = module.currentConfiguration.panelHotkey
        recorderState = HotkeyRecorderState(value: module.currentConfiguration.panelHotkey)
      } else if isViewPresented, case .registrationFailed = result {
        recorderFocusRequestID &+= 1
      }
    }
  }

  private func showOnboardingAgain() {
    localMessage = nil
    Task {
      let saved = await module.showOnboardingAgain()
      if !saved {
        localMessage = .failure("使用提示设置未能保存，请稍后重试。")
      }
    }
  }

  private func performWebsiteIconMaintenance(_ operation: WebsiteIconMaintenance) {
    guard websiteIconMaintenance == nil else { return }
    websiteIconMaintenance = operation
    Task {
      switch operation {
      case .backfill:
        await module.backfillWebsiteIcons()
      case .clearCache:
        await module.clearAutomaticWebsiteIconCache()
      }
      websiteIconMaintenance = nil
    }
  }

  private func synchronizeCommittedSettingsIfAppropriate() {
    guard !recorderState.isFocused,
      panelHotkeyCandidate == panelHotkeyBaseline
        || panelHotkeyCandidate == module.currentConfiguration.panelHotkey
    else { return }
    panelHotkeyCandidate = module.currentConfiguration.panelHotkey
    panelHotkeyBaseline = module.currentConfiguration.panelHotkey
    recorderState = HotkeyRecorderState(value: module.currentConfiguration.panelHotkey)
  }
}

private enum WebsiteIconMaintenance: Equatable {
  case backfill
  case clearCache
}

private struct SettingsMessage: Equatable {
  let text: String
  let systemImage: String
  let isError: Bool

  static func failure(_ text: String) -> SettingsMessage {
    SettingsMessage(text: text, systemImage: "xmark.octagon.fill", isError: true)
  }

  init(result: LauncherCommitResult, operation: String) {
    switch result {
    case .committed:
      text = "\(operation)已保存。"
      systemImage = "checkmark.circle.fill"
      isError = false
    case .rejected(.noChanges):
      text = "\(operation)没有变化。"
      systemImage = "info.circle"
      isError = false
    case .rejected(.transactionInProgress):
      text = "请先完成当前保存或批量整理，再修改\(operation)。"
      systemImage = "exclamationmark.triangle.fill"
      isError = true
    case .rejected:
      text = "\(operation)暂时无法保存，请稍后重试。"
      systemImage = "exclamationmark.triangle.fill"
      isError = true
    case .validationFailed:
      text = "\(operation)无效，请重新选择。"
      systemImage = "exclamationmark.triangle.fill"
      isError = true
    case .registrationFailed:
      text = "这个组合被系统或其他软件占用，原来的快捷键保持不变。"
      systemImage = "exclamationmark.triangle.fill"
      isError = true
    case .persistenceFailed:
      text = "\(operation)未能保存，原来的设置保持不变。"
      systemImage = "xmark.octagon.fill"
      isError = true
    }
  }

  private init(text: String, systemImage: String, isError: Bool) {
    self.text = text
    self.systemImage = systemImage
    self.isError = isError
  }
}

struct ModifierPicker: View {
  @Binding var selection: ModifierSet

  var body: some View {
    HStack(spacing: 8) {
      Text("修饰键")
      modifierButton("⌃ Control", value: .control)
      modifierButton("⌥ Option", value: .option)
      modifierButton("⇧ Shift", value: .shift)
      modifierButton("⌘ Command", value: .command)
      Spacer()
    }
  }

  private func modifierButton(_ title: String, value: ModifierSet) -> some View {
    Button(title) {
      if selection.contains(value) {
        selection.remove(value)
      } else {
        selection.insert(value)
      }
    }
    .buttonStyle(.bordered)
    .tint(selection.contains(value) ? .accentColor : .gray)
  }
}
