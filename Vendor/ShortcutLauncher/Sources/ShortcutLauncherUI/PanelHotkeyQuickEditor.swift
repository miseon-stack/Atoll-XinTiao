import ShortcutLauncherCore
import SwiftUI

/// A focused, panel-local editor for the one shortcut users need in order to
/// return to this interface. It deliberately reuses the module's independent,
/// revision-aware settings transaction instead of creating a batch draft.
struct PanelHotkeyQuickEditor: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var module: ShortcutLauncherModule

  @State private var candidate: HotkeyDefinition?
  @State private var baseline: HotkeyDefinition
  @State private var baselineRevision: UInt64
  @State private var recorderSessionID = UUID()
  @State private var recorderFocusRequestID: UInt64 = 0
  @State private var message: PanelHotkeyQuickEditorMessage?
  @State private var isSaving = false
  @State private var isPresented = false
  @State private var hasStaleBaseline = false

  init(module: ShortcutLauncherModule) {
    self.module = module
    let current = module.currentConfiguration.panelHotkey
    _candidate = State(initialValue: current)
    _baseline = State(initialValue: current)
    _baselineRevision = State(initialValue: module.configurationRevision)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "keyboard.badge.ellipsis")
          .font(.title3)
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("修改打开面板快捷键")
            .font(.headline)
          Text("当前：\(module.activePanelHotkeyDisplayName)")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }

      HotkeyRecorderView(
        hotkey: candidateBinding,
        labelSnapshot: module.keyLabelSnapshot,
        accessibilityIdentifier: "launcher.panelHotkey.recorder",
        focusRequestID: recorderFocusRequestID,
        onActivationRequest: {
          guard isPresented, !isSaving, !module.isCommitting, !module.isEditing else {
            return false
          }
          let isReady = await module.beginHotkeyRecorderSession(recorderSessionID)
          guard isPresented, isReady, !isSaving, !module.isCommitting else {
            await module.endHotkeyRecorderSession(recorderSessionID)
            return false
          }
          return true
        },
        onDeactivation: {
          await module.endHotkeyRecorderSession(recorderSessionID)
        }
      )
      .disabled(isSaving || module.isCommitting || module.isEditing)
      .frame(maxWidth: .infinity, minHeight: 44)

      if hasStaleBaseline {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Label("设置已在其他位置更新，请先载入最新快捷键。", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption)
            .foregroundStyle(.orange)
          Spacer(minLength: 8)
          Button("载入最新") {
            synchronizeToCurrentConfiguration()
            message = nil
            recorderFocusRequestID &+= 1
          }
          .controlSize(.small)
          .accessibilityIdentifier("launcher.panelHotkey.reloadLatest")
        }
        .accessibilityIdentifier("launcher.panelHotkey.staleWarning")
      } else if let message {
        Label(message.text, systemImage: message.systemImage)
          .font(.caption)
          .foregroundStyle(message.isError ? Color.orange : Color.secondary)
          .accessibilityIdentifier("launcher.panelHotkey.message")
      } else if let validationMessage {
        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("launcher.panelHotkey.validation")
      } else {
        Text("直接按下新的组合键，然后选择保存。只有注册与保存都成功，旧快捷键才会被替换。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Button("恢复默认") {
          candidate = .defaultPanel
          message = nil
        }
        .disabled(candidate == .defaultPanel || isSaving || module.isCommitting)
        .accessibilityIdentifier("launcher.panelHotkey.restoreDefault")

        Spacer()

        Button("取消") {
          Task {
            await module.endHotkeyRecorderSession(recorderSessionID)
            dismiss()
          }
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isSaving)
        .accessibilityIdentifier("launcher.panelHotkey.cancel")

        Button(isSaving ? "正在保存…" : "保存") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
        .accessibilityIdentifier("launcher.panelHotkey.save")
        .accessibilityHint("验证并保存新的打开面板快捷键")
      }
    }
    .padding(18)
    .frame(width: 390)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("launcher.panelHotkey.popover")
    .onAppear {
      let current = module.currentConfiguration.panelHotkey
      candidate = current
      baseline = current
      baselineRevision = module.configurationRevision
      hasStaleBaseline = false
      message = nil
      isPresented = true
      recorderFocusRequestID &+= 1
    }
    .onDisappear {
      isPresented = false
      Task { await module.endHotkeyRecorderSession(recorderSessionID) }
    }
    .onChange(of: module.configurationRevision) { _, _ in
      synchronizeCommittedValueIfAppropriate()
    }
  }

  private var candidateBinding: Binding<HotkeyDefinition?> {
    Binding(
      get: { candidate },
      set: { newValue in
        candidate = newValue
        message = nil
      }
    )
  }

  private var validationMessage: String? {
    guard let candidate else {
      return "打开面板快捷键不能为空；请重新录制或恢复默认。"
    }
    do {
      try candidate.validate()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private var canSave: Bool {
    candidate != nil
      && candidate != module.currentConfiguration.panelHotkey
      && validationMessage == nil
      && !hasStaleBaseline
      && !isSaving
      && !module.isCommitting
      && !module.isEditing
  }

  private func save() {
    guard canSave, let candidate else { return }
    isSaving = true
    message = nil
    Task {
      await module.endHotkeyRecorderSession(recorderSessionID)
      let result = await module.applyLauncherSettings(
        panelHotkey: candidate,
        directModeEnabled: module.currentConfiguration.directModeEnabled,
        expectedConfigurationRevision: baselineRevision
      )
      isSaving = false
      switch result {
      case .committed:
        synchronizeToCurrentConfiguration()
        dismiss()
      case .registrationFailed:
        message = .failure("这个组合被系统或其他软件占用，原来的快捷键保持不变。")
        recorderFocusRequestID &+= 1
      case .validationFailed:
        message = .failure("这个组合无效或与现有快捷键重复，请换一个组合。")
        recorderFocusRequestID &+= 1
      case .persistenceFailed(let code):
        switch code {
        case .readFailed:
          message = .failure("无法读取快捷键配置；新快捷键没有保存，请检查存储权限后重试。")
        case .writeFailed:
          message = .failure("新快捷键未能保存，已恢复原来的快捷键；请检查存储权限后重试。")
        case .recoveryIncomplete:
          message = .failure("保存失败，部分快捷键未能恢复；请暂停后重新启用快捷启动。")
        case .rollbackFailed:
          message = .failure("保存失败且磁盘配置未能完整恢复；请检查存储权限并重启后核对。")
        }
      case .rejected(.noChanges):
        synchronizeToCurrentConfiguration()
        dismiss()
      case .rejected(.transactionInProgress):
        message = .failure("当前正在保存其他修改，请稍后再试。")
      case .rejected(.staleRevision):
        hasStaleBaseline = true
        message = nil
      case .rejected:
        message = .failure("当前无法修改快捷键，请稍后再试。")
      }
    }
  }

  private func synchronizeCommittedValueIfAppropriate() {
    let current = module.currentConfiguration.panelHotkey
    let currentRevision = module.configurationRevision
    if candidate == baseline || candidate == current {
      candidate = current
      baseline = current
      baselineRevision = currentRevision
      hasStaleBaseline = false
      return
    }

    // A change to another setting can be safely rebased because the commit
    // candidate is rebuilt from the module's current configuration. A newer
    // panel shortcut, however, must never be overwritten without the user's
    // explicit acknowledgement.
    if current == baseline {
      baselineRevision = currentRevision
      return
    }

    hasStaleBaseline = true
    message = nil
  }

  private func synchronizeToCurrentConfiguration() {
    let current = module.currentConfiguration.panelHotkey
    candidate = current
    baseline = current
    baselineRevision = module.configurationRevision
    hasStaleBaseline = false
  }
}

private struct PanelHotkeyQuickEditorMessage: Equatable {
  let text: String
  let systemImage: String
  let isError: Bool

  static func failure(_ text: String) -> PanelHotkeyQuickEditorMessage {
    PanelHotkeyQuickEditorMessage(
      text: text,
      systemImage: "exclamationmark.triangle.fill",
      isError: true
    )
  }
}
