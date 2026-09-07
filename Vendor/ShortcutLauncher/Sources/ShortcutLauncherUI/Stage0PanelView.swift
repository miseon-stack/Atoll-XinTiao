import AppKit
import ShortcutLauncherCore
import SwiftUI

public struct LauncherPanelView: View {
  @Environment(\.launcherTheme) private var theme
  @ObservedObject private var module: ShortcutLauncherModule
  @State private var showsSettings = false
  @State private var showsPanelHotkeyEditor = false
  @FocusState private var focusedKeyCode: UInt16?
  @State private var dropTargets: Set<DropTargetMarker> = []
  @State private var pendingDropConfirmation: PendingDropConfirmation?

  private let dropCoordinator = LauncherDropCoordinator()

  public init(module: ShortcutLauncherModule) {
    self.module = module
  }

  public var body: some View {
    GeometryReader { proxy in
      let availableWidth = max(0, proxy.size.width - (theme.panelPadding * 2))
      let metrics = KeyboardLayoutMetrics.resolve(availableWidth: availableWidth)

      ZStack {
        Rectangle().fill(.regularMaterial)
        theme.panelTint.allowsHitTesting(false)

        ScrollView(.vertical) {
          VStack(spacing: theme.sectionSpacing) {
            header
            if module.uiPreferences.shouldShowOnboarding {
              onboardingGuide
            }
            keyboard(metrics: metrics, availableWidth: availableWidth)
            status
          }
          .padding(theme.panelPadding)
          .frame(maxWidth: .infinity)
        }

        if let feedback = module.feedbackEvent {
          VStack {
            Spacer()
            LauncherToast(
              event: feedback,
              undo: feedback.undoToken.map { token in
                { Task { await module.undo(token) } }
              },
              dismiss: module.dismissFeedback
            )
            .frame(maxWidth: 560)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
          }
          .padding(.horizontal, 24)
          .allowsHitTesting(true)
        }
      }
    }
    .frame(minWidth: 300, idealWidth: 1040, minHeight: 240, idealHeight: 570)
    .preferredColorScheme(preferredColorScheme)
    .animation(.easeOut(duration: theme.motionDuration), value: module.feedbackEvent?.id)
    .accessibilityIdentifier("launcher.panel")
    .sheet(item: bindingRequestItem, onDismiss: module.closeBindingEditor) { item in
      BindingEditorView(module: module, keyCode: item.keyCode)
    }
    .sheet(isPresented: $showsSettings) {
      LauncherSettingsView(module: module)
    }
    .alert("放弃全部修改？", isPresented: cancelConfirmationIsPresented) {
      Button("继续编辑", role: .cancel) {}
      Button("放弃修改", role: .destructive) { module.cancelEditing() }
    } message: {
      Text("当前编辑会话中的目标、槽位和快捷键修改都不会保存。")
    }
    .alert(item: $pendingDropConfirmation) { confirmation in
      Alert(
        title: Text("替换这个键位的绑定？"),
        message: Text(replacementMessage(for: confirmation.proposal)),
        primaryButton: .destructive(Text("替换")) {
          performDropProposal(confirmation.proposal)
        },
        secondaryButton: .cancel(Text("取消"))
      )
    }
    .onChange(of: module.quickBindingSession) { oldSession, newSession in
      if let oldSession, newSession == nil {
        focusedKeyCode = oldSession.keyCode
      }
    }
  }

  private var preferredColorScheme: ColorScheme? {
    switch theme.lockedAppearance ?? module.uiPreferences.appearance {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(theme.title)
          .font(.title2.bold())
        Text(
          module.isEditing && !module.isSingleBindingEditing
            ? "批量整理：移动、交换或集中修改键位"
            : theme.subtitle
        )
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()

      if module.isEditing && !module.isSingleBindingEditing {
        Button("恢复默认") { module.resetDraftToDefaults() }
          .disabled(module.isCommitting)
          .accessibilityIdentifier("launcher.edit.reset")
          .accessibilityHint("把全部槽位和快捷键加入恢复默认的草稿，保存后才生效")
        Button("取消") { module.requestCancelEditing() }
          .disabled(module.isCommitting)
          .accessibilityIdentifier("launcher.edit.cancel")
          .accessibilityHint("放弃本次批量草稿，已保存配置保持不变")
        Button(module.isCommitting ? "正在保存…" : commitButtonTitle) {
          Task { await module.commitEditing() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!module.canCommitEditing)
        .accessibilityIdentifier("launcher.edit.commit")
        .accessibilityHint("验证并保存全部批量草稿，再更新系统快捷键")
      } else {
        Menu {
          Button("修改打开面板快捷键…") { showsPanelHotkeyEditor = true }
          Divider()
          Button("快捷启动设置…") { showsSettings = true }
          Button("批量整理键位…") { module.beginEditing() }
          Button("再次显示使用提示") {
            Task { await module.showOnboardingAgain() }
          }
          .disabled(module.uiPreferences.shouldShowOnboarding)
          Divider()
          Button("关闭面板") { module.dismissPanel() }
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("更多")
        .accessibilityIdentifier("launcher.more")
        .accessibilityLabel("更多操作")
      }
    }
  }

  private var onboardingGuide: some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkles")
        .font(.title3)
        .foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 3) {
        Text("从一个键位开始")
          .font(.subheadline.weight(.semibold))
        Text("点击任意空键位，搜索应用或输入网址；也可以选择文件、文件夹。新绑定默认使用 Control + 该键位。右下角可以修改打开面板快捷键。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("知道了") {
        Task { await module.acknowledgeOnboarding() }
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("launcher.onboarding.dismiss")
      .accessibilityHint("隐藏这条提示；以后可从更多菜单重新显示")
    }
    .padding(12)
    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("launcher.onboarding")
  }

  private func moveFocus(from keyCode: UInt16, direction: MoveCommandDirection) {
    guard let rowIndex = KeySlotCatalog.rows.firstIndex(where: { row in
      row.contains(where: { $0.keyCode == keyCode })
    }),
      let columnIndex = KeySlotCatalog.rows[rowIndex].firstIndex(where: {
        $0.keyCode == keyCode
      })
    else { return }

    let destination: KeySlotDefinition?
    switch direction {
    case .left:
      destination = columnIndex > 0
        ? KeySlotCatalog.rows[rowIndex][columnIndex - 1]
        : nil
    case .right:
      destination = columnIndex + 1 < KeySlotCatalog.rows[rowIndex].count
        ? KeySlotCatalog.rows[rowIndex][columnIndex + 1]
        : nil
    case .up:
      guard rowIndex > 0 else { return }
      let upperRow = KeySlotCatalog.rows[rowIndex - 1]
      destination = upperRow[min(columnIndex, upperRow.count - 1)]
    case .down:
      guard rowIndex + 1 < KeySlotCatalog.rows.count else { return }
      let lowerRow = KeySlotCatalog.rows[rowIndex + 1]
      destination = lowerRow[min(columnIndex, lowerRow.count - 1)]
    @unknown default:
      destination = nil
    }
    focusedKeyCode = destination?.keyCode
  }

  @ViewBuilder
  private func keyboard(
    metrics: KeyboardLayoutMetrics,
    availableWidth: CGFloat
  ) -> some View {
    let content = VStack(spacing: metrics.verticalSpacing) {
      ForEach(Array(KeySlotCatalog.rows.enumerated()), id: \.offset) { rowIndex, row in
        HStack(spacing: metrics.horizontalSpacing) {
          if rowIndex > 0 { Spacer().frame(width: CGFloat(rowIndex) * metrics.rowIndent) }
          ForEach(row) { slot in keySlot(slot, metrics: metrics) }
          if rowIndex > 0 { Spacer().frame(width: CGFloat(rowIndex) * metrics.rowIndent) }
        }
      }
    }
    .frame(minWidth: metrics.contentWidth)
    .padding(.vertical, 4)

    if metrics.usesHorizontalScrolling {
      ScrollView(.horizontal) { content }
        .accessibilityIdentifier("launcher.keyboard")
    } else {
      content
        .frame(width: availableWidth)
        .accessibilityIdentifier("launcher.keyboard")
    }
  }

  private func keySlot(
    _ slot: KeySlotDefinition,
    metrics: KeyboardLayoutMetrics
  ) -> some View {
    let presentation = module.bindingPresentation(for: slot.keyCode)
    let record = module.bindingRecord(for: slot.keyCode)
    let hasPresentedBinding = presentation.bindingID != nil && presentation.displayName != nil
    let quickSessionID = module.quickBindingSession.flatMap {
      $0.keyCode == slot.keyCode ? $0.id : nil
    }
    let quickPresentationID = module.quickBindingSession.flatMap {
      $0.keyCode == slot.keyCode ? $0.presentationID : nil
    }

    return LauncherKeyCard(
      slot: slot,
      presentation: presentation,
      bindingID: record?.id,
      target: record?.target,
      websiteIconProvider: module.websiteIconProvider,
      metrics: metrics,
      isBusy: module.isBusy(slot.keyCode),
      isKeyboardFocused: focusedKeyCode == slot.keyCode,
      isDropTarget: dropTargets.contains(where: { $0.keyCode == slot.keyCode }),
      showsSuccess: module.feedbackEvent?.kind == .success
        && module.feedbackEvent?.slotKeyCode == slot.keyCode,
      action: {
        if module.isEditing {
          module.requestBinding(for: slot.keyCode)
        } else if hasPresentedBinding {
          Task { await module.executeBinding(keyCode: slot.keyCode, source: .panelClick) }
        } else {
          module.requestQuickBinding(for: slot.keyCode)
        }
      },
      replaceAction: {
        module.requestQuickBinding(for: slot.keyCode)
      },
      advancedAction: {
        if module.isEditing {
          module.requestBinding(for: slot.keyCode)
        } else {
          module.requestQuickBinding(for: slot.keyCode)
        }
      },
      removeAction: {
        removeBinding(at: slot.keyCode)
      },
      refreshWebsiteIconAction: record?.target.kind == .web
        ? { Task { await module.refreshWebsiteIcon(for: slot.keyCode) } }
        : nil,
      chooseWebsiteIconAction: record?.target.kind == .web && module.canManageWebsiteIcons
        ? { Task { await module.chooseCustomWebsiteIcon(for: slot.keyCode) } }
        : nil,
      restoreWebsiteIconAction: record?.target.kind == .web && module.canManageWebsiteIcons
        ? { Task { await module.restoreAutomaticWebsiteIcon(for: slot.keyCode) } }
        : nil
    )
    .focusable(true)
    .focusEffectDisabled()
    .focused($focusedKeyCode, equals: slot.keyCode)
    .onMoveCommand { direction in
      moveFocus(from: slot.keyCode, direction: direction)
    }
    .popover(
      isPresented: quickBindingIsPresented(
        for: slot.keyCode,
        sessionID: quickSessionID,
        presentationID: quickPresentationID
      ),
      attachmentAnchor: .rect(.bounds),
      arrowEdge: .top
    ) {
      if let session = module.quickBindingSession, session.keyCode == slot.keyCode {
        QuickBindingPopover(
          module: module,
          keyCode: slot.keyCode,
          sessionID: session.id
        )
        .id(session.presentationID)
      }
    }
    .modifier(ConditionalSlotDragModifier(
      transfer: module.isEditing && !module.isCommitting && record != nil
        ? LauncherSlotTransfer(sourceKeyCode: slot.keyCode)
        : nil
    ))
    .dropDestination(for: LauncherSlotTransfer.self) { transfers, _ in
      prepareDrop(
        transfers.compactMap { try? LauncherDropItem.internalSlot($0) },
        destinationKeyCode: slot.keyCode
      )
    } isTargeted: { isTargeted in
      updateDropTarget(
        keyCode: slot.keyCode,
        representation: .internalSlot,
        isTargeted: isTargeted
      )
    }
    .dropDestination(for: URL.self) { urls, _ in
      prepareDrop(
        urls.map { $0.isFileURL ? .fileURL($0) : .webURL($0) },
        destinationKeyCode: slot.keyCode
      )
    } isTargeted: { isTargeted in
      updateDropTarget(
        keyCode: slot.keyCode,
        representation: .url,
        isTargeted: isTargeted
      )
    }
    .dropDestination(for: String.self) { values, _ in
      prepareDrop(values.map(LauncherDropItem.plainText), destinationKeyCode: slot.keyCode)
    } isTargeted: { isTargeted in
      updateDropTarget(
        keyCode: slot.keyCode,
        representation: .plainText,
        isTargeted: isTargeted
      )
    }
    .contextMenu {
      if hasPresentedBinding {
        Button("打开 \(presentation.displayName ?? "目标")") {
          Task { await module.executeBinding(keyCode: slot.keyCode, source: .panelClick) }
        }
        Button(isTargetUnavailable(presentation.runtimeState) ? "重新定位…" : "更换目标…") {
          module.requestQuickBinding(for: slot.keyCode)
        }
        Button("快捷键与目标设置…") {
          if module.isEditing {
            module.requestBinding(for: slot.keyCode)
          } else {
            module.requestQuickBinding(for: slot.keyCode)
          }
        }
        if record?.target.kind == .web {
          Divider()
          Button("刷新网站图标") {
            Task { await module.refreshWebsiteIcon(for: slot.keyCode) }
          }
          if module.canManageWebsiteIcons {
            Button("选择自定义图标…") {
              Task { await module.chooseCustomWebsiteIcon(for: slot.keyCode) }
            }
            Button("恢复网站图标") {
              Task { await module.restoreAutomaticWebsiteIcon(for: slot.keyCode) }
            }
          }
        }
        if module.isEditing && !module.isSingleBindingEditing {
          Menu("移动或交换到…") {
            ForEach(KeySlotCatalog.all.filter { $0.keyCode != slot.keyCode }) { destination in
              Button("面板键 \(module.keyLabel(for: destination.keyCode))") {
                module.moveBinding(from: slot.keyCode, to: destination.keyCode)
              }
            }
          }
          .accessibilityHint("无需拖拽即可移动到空槽，或与已有绑定交换")
        }
        Divider()
        Button("移除绑定", role: .destructive) {
          removeBinding(at: slot.keyCode)
        }
      } else {
        Button("添加快捷启动…") { module.requestQuickBinding(for: slot.keyCode) }
      }
    }
  }

  private func removeBinding(at keyCode: UInt16) {
    if module.isEditing {
      module.clearBinding(for: keyCode)
    } else {
      Task { await module.quickRemoveBinding(for: keyCode) }
    }
  }

  private func updateDropTarget(
    keyCode: UInt16,
    representation: DropRepresentation,
    isTargeted: Bool
  ) {
    let marker = DropTargetMarker(keyCode: keyCode, representation: representation)
    if isTargeted {
      dropTargets.insert(marker)
    } else {
      dropTargets.remove(marker)
    }
  }

  private func prepareDrop(
    _ items: [LauncherDropItem],
    destinationKeyCode: UInt16
  ) -> Bool {
    do {
      let proposal = try dropCoordinator.prepare(
        items: items,
        destinationKeyCode: destinationKeyCode,
        bindings: module.displayedConfiguration.bindings
      )
      switch proposal {
      case .move, .swap:
        guard module.isEditing, !module.isCommitting else {
          throw LauncherDropError.unsupportedRepresentation
        }
      case .bind, .replace:
        guard !module.isEditing, !module.isCommitting else {
          throw LauncherDropError.unsupportedRepresentation
        }
      }

      dropTargets = dropTargets.filter { $0.keyCode != destinationKeyCode }
      focusedKeyCode = destinationKeyCode
      if proposal.requiresReplacementConfirmation {
        pendingDropConfirmation = PendingDropConfirmation(proposal: proposal)
      } else {
        performDropProposal(proposal)
      }
      return true
    } catch {
      dropTargets = dropTargets.filter { $0.keyCode != destinationKeyCode }
      let message = "无法绑定拖入内容：\(error.localizedDescription)；原绑定没有改变。"
      module.errorMessage = message
      if let application = NSApp {
        NSAccessibility.post(
          element: application,
          notification: .announcementRequested,
          userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
          ]
        )
      }
      return false
    }
  }

  private func performDropProposal(_ proposal: LauncherDropProposal) {
    switch proposal {
    case .bind(let target, let destinationKeyCode),
      .replace(let target, let destinationKeyCode, _):
      focusedKeyCode = destinationKeyCode
      Task { @MainActor in
        do {
          _ = try await module.bindDroppedTarget(
            url: target.lastKnownURL,
            kind: target.kind,
            to: destinationKeyCode
          )
        } catch {
          module.errorMessage = "拖放绑定失败；原绑定没有改变，请重试。"
        }
        focusedKeyCode = destinationKeyCode
      }
    case .move(let sourceKeyCode, let destinationKeyCode),
      .swap(let sourceKeyCode, let destinationKeyCode):
      module.moveBinding(from: sourceKeyCode, to: destinationKeyCode)
      focusedKeyCode = destinationKeyCode
    }
  }

  private func replacementMessage(for proposal: LauncherDropProposal) -> String {
    guard case .replace(let target, let destinationKeyCode, _) = proposal else {
      return ""
    }
    let currentName = module.bindingRecord(for: destinationKeyCode)?.target.displayName ?? "当前目标"
    return "“\(currentName)”将更换为“\(target.displayName)”。成功后可以撤销；不会删除原文件、应用或网站。"
  }

  @ViewBuilder
  private func targetIcon(_ target: LaunchTarget?, kind: LaunchTargetKind?) -> some View {
    if let target {
      if target.kind == .web {
        ZStack {
          RoundedRectangle(cornerRadius: 8).fill(.blue.gradient)
          Text(String((target.lastKnownURL.host ?? "W").prefix(1)).uppercased())
            .font(.headline.bold()).foregroundStyle(.white)
        }
      } else {
        Image(nsImage: NSWorkspace.shared.icon(forFile: target.lastKnownURL.path))
          .resizable().scaledToFit()
      }
    } else if let kind {
      Image(systemName: targetSystemImage(kind))
        .resizable().scaledToFit().foregroundStyle(.secondary).padding(7)
    } else {
      Image(systemName: "plus")
        .resizable().scaledToFit().foregroundStyle(.tertiary).padding(9)
    }
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 4) {
      if module.isEditing || module.isCommitting || module.errorMessage != nil {
        HStack(spacing: 8) {
          Image(systemName: module.isCommitting ? "arrow.triangle.2.circlepath" : (module.errorMessage == nil ? "pencil.circle.fill" : "exclamationmark.triangle.fill"))
            .foregroundStyle(module.errorMessage == nil ? Color.secondary : Color.orange)
          Text(module.statusText).font(.caption).lineLimit(2)
          Spacer()
          if module.errorMessage != nil {
            Button("关闭") { module.errorMessage = nil }
              .buttonStyle(.link)
              .accessibilityIdentifier("launcher.error.dismiss")
          }
        }
      }
      if let validation = module.draftValidationMessage {
        Label(validation, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      }
      if let prompt = module.repairPrompt {
        HStack(spacing: 8) {
          Label(
            "无法打开 \(prompt.displayName)，旧绑定仍保留。",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
          Spacer()
          Button("修复绑定") { module.openRepairPrompt() }
            .accessibilityIdentifier("launcher.feedback.repair")
            .accessibilityHint("打开对应槽位，重新选择目标或调整快捷键")
          Button("稍后") { module.dismissRepairPrompt() }
            .accessibilityIdentifier("launcher.feedback.dismiss")
        }
      }
      if !module.isEditing {
        HStack {
          if !module.isCommitting && module.errorMessage == nil && module.repairPrompt == nil {
            if !issueKeyCodes.isEmpty {
              Button {
                focusedKeyCode = issueKeyCodes.first
              } label: {
                Label("\(issueKeyCodes.count) 个键位需要处理", systemImage: "exclamationmark.triangle.fill")
              }
              .buttonStyle(.link)
              .foregroundStyle(.orange)
              .accessibilityIdentifier("launcher.issue-summary")
              .accessibilityHint("把键盘焦点移到第一个有问题的键位")
            } else if !module.isArmed {
              Label("请先释放唤出组合键；鼠标点击仍可直接使用", systemImage: "keyboard.badge.ellipsis")
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
              Text("点击键位即可打开或绑定；悬停、聚焦或右键可管理")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
          Spacer()
          panelHotkeyButton
        }
      }
    }
  }

  private var panelHotkeyButton: some View {
    Button {
      showsPanelHotkeyEditor = true
    } label: {
      HStack(spacing: 6) {
        Text("打开面板快捷键：")
        Text(module.activePanelHotkeyDisplayName)
          .font(.caption2.monospaced().weight(.semibold))
        Image(systemName: "pencil")
          .font(.caption2.weight(.semibold))
      }
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .controlSize(.small)
    .disabled(module.isCommitting)
    .help("修改打开快捷启动面板的快捷键")
    .accessibilityIdentifier("launcher.panelHotkey.edit")
    .accessibilityLabel("打开面板快捷键，当前为 \(module.activePanelHotkeyDisplayName)，修改")
    .accessibilityHint("打开快捷键录制窗口")
    .popover(isPresented: $showsPanelHotkeyEditor, arrowEdge: .bottom) {
      PanelHotkeyQuickEditor(module: module)
    }
  }

  private var issueKeyCodes: [UInt16] {
    module.bindingPresentations.compactMap { presentation in
      switch presentation.runtimeState {
      case .conflicted, .targetUnavailable:
        presentation.slotKeyCode
      default:
        nil
      }
    }
  }

  private func quickBindingIsPresented(
    for keyCode: UInt16,
    sessionID: UUID?,
    presentationID: UUID?
  ) -> Binding<Bool> {
    Binding(
      get: { module.isQuickBindingPopoverPresented(for: keyCode) },
      set: { isPresented in
        if isPresented {
          module.requestQuickBinding(for: keyCode)
        } else if let sessionID, let presentationID {
          module.quickBindingPresentationDidDismiss(
            for: keyCode,
            sessionID: sessionID,
            presentationID: presentationID
          )
        }
      }
    )
  }

  private var bindingRequestItem: Binding<BindingRequestItem?> {
    Binding(
      get: { module.bindingRequestKeyCode.map(BindingRequestItem.init) },
      set: { item in
        if let item {
          module.bindingRequestKeyCode = item.keyCode
        } else {
          module.closeBindingEditor()
        }
      }
    )
  }

  private var cancelConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { module.cancelConfirmationRequested },
      set: { module.cancelConfirmationRequested = $0 }
    )
  }

  private func slotHelp(_ presentation: BindingPresentation) -> String {
    guard let name = presentation.displayName else {
      return "面板键 \(presentation.panelKeyLabel)：点击创建绑定"
    }
    return "面板键 \(presentation.panelKeyLabel)：\(name)，\(statePresentation(for: presentation).text)"
  }

  private func accessibilityLabel(_ presentation: BindingPresentation) -> String {
    guard let name = presentation.displayName else {
      return "键位 \(presentation.panelKeyLabel)，未绑定"
    }
    let kind = presentation.targetKind?.displayName ?? "目标"
    return "键位 \(presentation.panelKeyLabel)，\(kind) \(name)，\(statePresentation(for: presentation).text)"
  }

  private var commitButtonTitle: String {
    module.directModeEnabled && module.directShortcutCount > 0 ? "保存并启用" : "保存修改"
  }

  private var panelHotkeyStatusText: String {
    if module.isEditing, module.panelHotkeyDisplayName != module.activePanelHotkeyDisplayName {
      return "当前唤出：\(module.activePanelHotkeyDisplayName) · 待保存：\(module.panelHotkeyDisplayName)"
    }
    return "唤出：\(module.activePanelHotkeyDisplayName)"
  }

  private var directHeaderText: String {
    if module.directShortcutCount == 0 {
      return "全局快捷键：未设置（当前仅面板可用）"
    }
    if module.hasPendingDirectChanges {
      return "\(module.directShortcutSummary)，待保存"
    }
    let enabledCount = module.bindingPresentations.filter {
      if case .enabled = $0.runtimeState { return true }
      return false
    }.count
    let conflictCount = module.bindingPresentations.filter {
      if case .conflicted = $0.runtimeState { return true }
      return false
    }.count
    if conflictCount > 0 {
      return enabledCount > 0
        ? "全局快捷键：\(enabledCount) 个已启用，\(conflictCount) 个冲突"
        : "全局快捷键：\(conflictCount) 个冲突"
    }
    let pausedCount = module.bindingPresentations.filter {
      if case .paused = $0.runtimeState { return true }
      return false
    }.count
    if pausedCount > 0 { return "全局快捷键：\(pausedCount) 个已暂停" }
    return "全局快捷键：\(enabledCount) 个已启用"
  }

  private var directHeaderSystemImage: String {
    if module.directShortcutCount == 0 { return "bolt.slash.fill" }
    if module.hasPendingDirectChanges { return "clock.badge.exclamationmark" }
    if module.bindingPresentations.contains(where: {
      if case .conflicted = $0.runtimeState { return true }
      return false
    }) { return "exclamationmark.triangle.fill" }
    return module.bindingPresentations.contains(where: {
      if case .enabled = $0.runtimeState { return true }
      return false
    }) ? "bolt.fill" : "pause.circle.fill"
  }

  private var directHeaderColor: Color {
    if module.directShortcutCount == 0 || module.hasPendingDirectChanges {
      return .orange
    }
    if module.bindingPresentations.contains(where: {
      if case .conflicted = $0.runtimeState { return true }
      return false
    }) { return .orange }
    return module.bindingPresentations.contains(where: {
      if case .enabled = $0.runtimeState { return true }
      return false
    }) ? .secondary : .orange
  }

  private func statePresentation(
    for presentation: BindingPresentation
  ) -> SlotStatePresentation {
    switch presentation.runtimeState {
    case .unbound:
      SlotStatePresentation(
        text: "未绑定",
        color: .secondary,
        borderColor: .white.opacity(0.08)
      )
    case .panelOnly:
      SlotStatePresentation(
        text: "仅面板 · \(presentation.panelKeyLabel)",
        color: .secondary,
        borderColor: .white.opacity(0.08)
      )
    case .pending(let candidate):
      SlotStatePresentation(
        text: candidate == nil
          ? "待保存 · 仅面板"
          : "待保存 · \(presentation.directHotkeyLabel ?? "新组合")",
        color: .orange,
        borderColor: .orange.opacity(0.8)
      )
    case .enabled:
      SlotStatePresentation(
        text: "已启用 · \(presentation.directHotkeyLabel ?? "全局组合")",
        color: .secondary,
        borderColor: .green.opacity(0.55)
      )
    case .paused:
      SlotStatePresentation(
        text: "已暂停 · \(presentation.directHotkeyLabel ?? "全局组合")",
        color: .orange,
        borderColor: .orange.opacity(0.55)
      )
    case .conflicted:
      SlotStatePresentation(
        text: "冲突 · \(presentation.directHotkeyLabel ?? "全局组合")",
        color: .orange,
        borderColor: .orange
      )
    case .targetUnavailable:
      SlotStatePresentation(
        text: presentation.directHotkeyLabel.map { "目标失效 · \($0)" } ?? "目标失效",
        color: .red,
        borderColor: .red
      )
    }
  }

  private func isTargetUnavailable(_ state: BindingRuntimeState) -> Bool {
    if case .targetUnavailable = state { return true }
    return false
  }

  private func targetSystemImage(_ kind: LaunchTargetKind) -> String {
    switch kind {
    case .application: "app"
    case .file: "doc"
    case .folder: "folder"
    case .web: "globe"
    }
  }
}

private struct SlotStatePresentation {
  let text: String
  let color: Color
  let borderColor: Color
}

@available(*, deprecated, renamed: "LauncherPanelView")
typealias Stage0PanelView = LauncherPanelView

private struct BindingRequestItem: Identifiable {
  let keyCode: UInt16
  var id: UInt16 { keyCode }
}

private enum DropRepresentation: Hashable {
  case internalSlot
  case url
  case plainText
}

private struct DropTargetMarker: Hashable {
  let keyCode: UInt16
  let representation: DropRepresentation
}

private struct PendingDropConfirmation: Identifiable {
  let id = UUID()
  let proposal: LauncherDropProposal
}

private struct ConditionalSlotDragModifier: ViewModifier {
  let transfer: LauncherSlotTransfer?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let transfer {
      content.draggable(transfer)
    } else {
      content
    }
  }
}

struct BindingEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var module: ShortcutLauncherModule
  let keyCode: UInt16
  private let startedWithBinding: Bool
  @State private var showsWebEntry = false
  // Keep the field empty so pasting a complete URL cannot accidentally create
  // values such as `https://https://example.com`. The placeholder still shows
  // the required shape without becoming part of the user's input.
  @State private var urlText = ""
  @State private var directCandidate: HotkeyDefinition?
  @State private var recorderState: HotkeyRecorderState
  @State private var showsDirectRemovalConfirmation = false
  @State private var recorderSessionID = UUID()
  @State private var recorderFocusRequestID: UInt64 = 0
  @State private var isViewPresented = false

  init(module: ShortcutLauncherModule, keyCode: UInt16) {
    self.module = module
    self.keyCode = keyCode
    let hotkey = module.directHotkey(for: keyCode)
    startedWithBinding = module.binding(for: keyCode) != nil
    _directCandidate = State(initialValue: hotkey)
    _recorderState = State(initialValue: HotkeyRecorderState(value: hotkey))
  }

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
        VStack(alignment: .leading) {
          Text("编辑面板按键 \(module.keyLabel(for: keyCode))").font(.title3.bold())
          Text(module.binding(for: keyCode)?.displayName ?? "尚未选择目标")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(module.isSingleBindingEditing ? "取消" : "返回批量编辑") {
          cancelAndDismiss()
        }
        .accessibilityIdentifier("launcher.cancel.header")
        .accessibilityHint(
          module.isSingleBindingEditing
            ? "放弃本次单槽位修改并返回面板"
            : "保留批量草稿并返回面板"
        )
        }

        GroupBox("打开目标") {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 10) {
            targetButton("应用", systemImage: "app", kind: .application)
            targetButton("文件", systemImage: "doc", kind: .file)
            targetButton("文件夹", systemImage: "folder", kind: .folder)
            Button { showsWebEntry.toggle() } label: {
              Label("网址", systemImage: "globe").frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.bordered)
            .disabled(requiredRepairKind.map { $0 != .web } ?? false)
            .accessibilityIdentifier("launcher.target.web")
            .accessibilityHint("输入一个 HTTP 或 HTTPS 网址")
          }
          if showsWebEntry {
            HStack {
              TextField("https://example.com", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("launcher.target.web.input")
              Button("加入草稿") {
                module.bindWebURL(urlText, to: keyCode)
                if module.errorMessage == nil { showsWebEntry = false }
              }
              .accessibilityIdentifier("launcher.target.web.confirm")
              .accessibilityHint("校验网址并加入当前槽位草稿，尚不会保存")
            }
            Text("仅支持 HTTP(S)；不会联网抓取网页图标。")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let requiredRepairKind {
            Label(
              "目标失效：请重新选择同类型的\(requiredRepairKind.displayName)，槽位、绑定身份和全局组合会保持不变。",
              systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          }
        }.padding(.vertical, 6)
        }

        GroupBox("全局快捷键（可选）") {
        VStack(alignment: .leading, spacing: 12) {
          Text(
            startedWithBinding
              ? "也可以保留为仅面板使用"
              : "为当前选择的面板键设置全局快捷键，也可以保留为仅面板使用"
          )
            .font(.caption)
            .foregroundStyle(.secondary)
          HotkeyRecorderView(
            hotkey: directCandidateBinding,
            labelSnapshot: module.keyLabelSnapshot,
            accessibilityIdentifier: "launcher.hotkey.recorder",
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
            }
          ) { state in
            recorderState = state
          }
          .disabled(module.binding(for: keyCode) == nil || module.isCommitting)
          .frame(maxWidth: .infinity, minHeight: 44)

          HStack(spacing: 10) {
            if directCandidate != nil {
              Button("清除全局快捷键", role: .destructive) {
                if persistedDirectHotkey != nil {
                  showsDirectRemovalConfirmation = true
                } else {
                  setDirectCandidate(nil)
                }
              }
              .accessibilityIdentifier("launcher.hotkey.clear")
              .accessibilityHint("只清除这个绑定的全局组合；打开目标不受影响")
            }
            if isPersistedConflict, let bindingID = presentation.bindingID {
              Button("重新尝试启用") {
                Task {
                  await module.endHotkeyRecorderSession(recorderSessionID)
                  let result = await module.retryDirectHotkey(bindingID: bindingID)
                  if case .stillConflicted = result, shouldRequestRecorderFocus {
                    recorderFocusRequestID &+= 1
                  }
                }
              }
              .accessibilityIdentifier("launcher.hotkey.retry")
              .accessibilityHint("只重新注册这个绑定，不修改配置或其他快捷键")
              .disabled(module.hasEditingChanges)
            }
            Spacer()
            if let directCandidate {
              Text("候选：\(module.hotkeyDisplayName(directCandidate))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }

          if let recorderValidationMessage {
            Label(recorderValidationMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          } else if let draftValidationMessage = module.draftValidationMessage {
            Label(draftValidationMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          } else if module.binding(for: keyCode) == nil {
            Label("先选择一个打开目标，再录制全局快捷键。", systemImage: "arrow.up.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if isPersistedConflict {
            Label(
              "这个已保存组合当前被系统或其他软件占用。可直接重试，或录制新组合后保存。",
              systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          } else if directCandidate == nil {
            Label(
              "未设置全局快捷键；保存后仍可从面板按 \(module.keyLabel(for: keyCode)) 打开。",
              systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            Label(
              "候选只在草稿中；点击“保存并启用”后才会交给系统验证和注册。",
              systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Text("若组合被系统或其他软件占用，保存会失败并完整保留旧配置。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }.padding(.vertical, 6)
        }

        if let errorMessage = module.errorMessage {
        Label(errorMessage, systemImage: "xmark.octagon.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
        }

        HStack {
        if module.binding(for: keyCode) != nil {
          Button(module.isSingleBindingEditing ? "移除并保存绑定" : "从批量草稿移除", role: .destructive) {
            removeBinding()
          }
          .accessibilityIdentifier("launcher.binding.remove")
          .accessibilityHint(
            module.isSingleBindingEditing
              ? "保存后只移除这个绑定，不删除真实目标"
              : "只从当前批量草稿移除这个绑定"
          )
        }
        Spacer()
        Button(module.isSingleBindingEditing ? "取消" : "返回") {
          cancelAndDismiss()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("launcher.cancel")
        .accessibilityHint(
          module.isSingleBindingEditing
            ? "放弃当前槽位修改并返回面板"
            : "保留批量草稿并返回面板"
        )

        if shouldShowPanelOnlyAction {
          if directCandidate == nil {
            Button(module.isCommitting ? "正在保存…" : "仅保存到面板") {
              commit(panelOnly: true)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("launcher.commit.panelOnly")
            .accessibilityHint("保存目标但不创建全局快捷键")
            .disabled(!canSave)
          } else {
            Button(module.isCommitting ? "正在保存…" : "仅保存到面板") {
              commit(panelOnly: true)
            }
            .accessibilityIdentifier("launcher.commit.panelOnly")
            .accessibilityHint("保存目标并移除当前草稿中的全局组合")
            .disabled(!canSave)
          }
        }

        if directCandidate != nil || startedWithBinding {
          Button(module.isCommitting ? "正在保存…" : saveButtonTitle) {
            commit(panelOnly: false)
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier(saveAccessibilityIdentifier)
          .accessibilityHint(
            directCandidate == nil
              ? "保存当前槽位，并保持只从面板打开"
              : "验证、保存并启用显示的全局快捷键"
          )
          .disabled(!canSave)
        }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 340, idealWidth: 660, minHeight: 280, idealHeight: 620)
    .disabled(module.isCommitting)
    .accessibilityIdentifier("launcher.edit.single")
    .onAppear { isViewPresented = true }
    .onDisappear {
      isViewPresented = false
      Task { await module.endHotkeyRecorderSession(recorderSessionID) }
    }
    .alert("移除全局快捷键？", isPresented: $showsDirectRemovalConfirmation) {
      Button("取消", role: .cancel) {}
      Button("移除组合", role: .destructive) { setDirectCandidate(nil) }
    } message: {
      Text("保存后，这个目标仍可通过面板按键打开，但当前全局组合将被注销。")
    }
  }

  private func targetButton(
    _ title: String,
    systemImage: String,
    kind: LaunchTargetKind
  ) -> some View {
    Button { module.chooseTarget(kind: kind, for: keyCode) } label: {
      Label(title, systemImage: systemImage).frame(maxWidth: .infinity, minHeight: 38)
    }
    .buttonStyle(.bordered)
    .disabled(requiredRepairKind.map { $0 != kind } ?? false)
    .accessibilityIdentifier("launcher.target.\(kind.rawValue)")
    .accessibilityHint("选择要绑定的\(title)")
  }

  private var presentation: BindingPresentation {
    module.bindingPresentation(for: keyCode)
  }

  private var requiredRepairKind: LaunchTargetKind? {
    module.requiredRepairTargetKind(for: keyCode)
  }

  private var directCandidateBinding: Binding<HotkeyDefinition?> {
    Binding(
      get: { directCandidate },
      set: { setDirectCandidate($0) }
    )
  }

  private var recorderValidationMessage: String? {
    if case .invalid(let code) = recorderState.phase { return code.message }
    return nil
  }

  var canSave: Bool {
    !module.isCommitting
      && recorderValidationMessage == nil
      && module.draftValidationMessage == nil
      && module.binding(for: keyCode) != nil
      && module.canCommitEditing
  }

  private var saveButtonTitle: String {
    guard let directCandidate else { return "保存修改" }
    if !module.directModeEnabled {
      return "保存修改（快捷键保持暂停）"
    }
    if startedWithBinding, directCandidate == persistedDirectHotkey {
      return "保存修改"
    }
    return "保存并启用 \(module.hotkeyDisplayName(directCandidate))"
  }

  private var saveAccessibilityIdentifier: String {
    guard let directCandidate else { return "launcher.commit.panelOnly" }
    return module.directModeEnabled && (!startedWithBinding || directCandidate != persistedDirectHotkey)
      ? "launcher.commit.enable"
      : "launcher.commit.save"
  }

  private var persistedDirectHotkey: HotkeyDefinition? {
    module.currentConfiguration.bindings[keyCode]?.directHotkey
  }

  private var shouldShowPanelOnlyAction: Bool {
    !startedWithBinding
  }

  private var isPersistedConflict: Bool {
    if case .conflicted = presentation.runtimeState { return true }
    return false
  }

  private func setDirectCandidate(_ value: HotkeyDefinition?) {
    directCandidate = value
    guard module.binding(for: keyCode) != nil else { return }
    module.setDraftDirectHotkey(value, for: keyCode)
  }

  private func cancelAndDismiss() {
    module.closeBindingEditor()
    dismiss()
  }

  private func commit(panelOnly: Bool) {
    Task {
      if panelOnly, directCandidate != nil {
        setDirectCandidate(nil)
      }
      await module.endHotkeyRecorderSession(recorderSessionID)
      let result = await module.commitEditingWithResult()
      if !module.isEditing {
        dismiss()
      } else if case .registrationFailed = result, shouldRequestRecorderFocus {
        recorderFocusRequestID &+= 1
      }
    }
  }

  private func removeBinding() {
    if module.isSingleBindingEditing {
      Task {
        module.clearBinding(for: keyCode)
        await module.endHotkeyRecorderSession(recorderSessionID)
        _ = await module.commitEditingWithResult()
        if !module.isEditing {
          dismiss()
        }
      }
    } else {
      module.clearBinding(for: keyCode)
      dismiss()
    }
  }

  private var shouldRequestRecorderFocus: Bool {
    isViewPresented
      && module.isEditing
      && module.bindingRequestKeyCode == keyCode
  }
}
