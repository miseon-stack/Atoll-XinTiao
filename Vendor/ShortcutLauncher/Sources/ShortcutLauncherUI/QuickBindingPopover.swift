import AppKit
import ShortcutLauncherCore
import SwiftUI

/// The ordinary one-slot flow: one input for applications and websites,
/// explicit local-target actions, progressive shortcut options, and immediate
/// revision-aware commit through `ShortcutLauncherModule`.
struct QuickBindingPopover: View {
  @ObservedObject var module: ShortcutLauncherModule
  @StateObject private var searchController: ApplicationSearchController

  let keyCode: UInt16
  let sessionID: UUID

  @State private var rawInput: String
  @State private var selectedCandidateID: String?
  @State private var isSubmitting = false
  @State private var inlineError: String?
  @State private var showsShortcutOptions: Bool
  @State private var selectedModifiers: ModifierSet
  @State private var usesPanelOnly: Bool
  @State private var shortcutWasCustomized: Bool
  @State private var focusRequestID: UInt64 = 0
  @FocusState private var focusedControl: QuickBindingFocusIntent?

  private enum UnifiedCandidate: Identifiable {
    case website(URL)
    case application(ApplicationDescriptor, generation: UInt64)

    var id: String {
      switch self {
      case .website(let url): "web:\(url.absoluteString)"
      case .application(let application, _): "application:\(application.id)"
      }
    }
  }

  init(
    module: ShortcutLauncherModule,
    keyCode: UInt16,
    sessionID: UUID,
    applicationCatalog: (any InstalledApplicationCataloging)? = nil
  ) {
    self.module = module
    self.keyCode = keyCode
    self.sessionID = sessionID

    let catalog = applicationCatalog ?? module.applicationCatalog
    let controller = ApplicationSearchController(catalog: catalog)
    _searchController = StateObject(wrappedValue: controller)

    let snapshot = module.quickBindingSession.flatMap {
      $0.id == sessionID ? $0.chooserSnapshot : nil
    } ?? QuickBindingChooserSnapshot()
    _rawInput = State(initialValue: snapshot.rawInput)
    _selectedCandidateID = State(initialValue: snapshot.selectedCandidateID)
    _showsShortcutOptions = State(initialValue: snapshot.showsShortcutOptions)
    _selectedModifiers = State(initialValue: snapshot.selectedModifiers)
    _usesPanelOnly = State(initialValue: snapshot.usesPanelOnly)
    _shortcutWasCustomized = State(initialValue: snapshot.shortcutWasCustomized)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      header
      primaryInput
      candidateResults
      localTargetActions

      if showsShortcutOptions {
        Divider()
        shortcutOptions
      }

      feedback
      footer
    }
    .padding(16)
    .frame(width: 410)
    .onAppear {
      searchController.updateQuery(rawInput)
      restoreSavedFocus()
      synchronizeChooserSnapshot()
    }
    .onDisappear {
      searchController.stop()
    }
    .onChange(of: searchController.snapshot) { _, _ in
      reconcileSelection()
    }
    .onChange(of: rawInput) { _, value in
      clearStaleError()
      searchController.updateQuery(value)
      selectedCandidateID = nil
      synchronizeChooserSnapshot()
    }
    .onChange(of: selectedCandidateID) { _, _ in
      synchronizeChooserSnapshot()
    }
    .onExitCommand {
      guard !isSubmitting else { return }
      module.closeQuickBinding(sessionID: sessionID)
    }
    .accessibilityIdentifier("launcher.quick.popover")
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(module.bindingRecord(for: keyCode) == nil ? "添加快捷启动" : "管理快捷启动")
          .font(.headline)
        Text("键位 \(keyLabel) · \(shortcutSummary)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        module.closeQuickBinding(sessionID: sessionID)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .disabled(isSubmitting)
      .help("关闭")
      .accessibilityLabel("关闭快速绑定")
      .accessibilityHint("关闭后不改变尚未提交的选择")
      .accessibilityIdentifier("launcher.quick.close")
    }
  }

  private var primaryInput: some View {
    HStack(spacing: 8) {
      ApplicationSearchField(
        text: $rawInput,
        prompt: "搜索应用或输入网址",
        focusRequestID: focusRequestID,
        onTextChange: { _ in },
        onMove: moveSelection,
        onSubmit: { hasMarkedText in
          guard !hasMarkedText else { return }
          submitSelectedCandidate()
        },
        onEscape: { hasMarkedText in
          guard !hasMarkedText else { return }
          module.closeQuickBinding(sessionID: sessionID)
        }
      )
      .frame(height: 26)
      .disabled(isSubmitting)

      Button {
        searchController.prewarmApplications(forceRefresh: true)
        searchController.refresh(preservingSelection: true)
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(isSubmitting || searchController.snapshot.isLoading)
      .help("刷新应用列表")
      .accessibilityIdentifier("launcher.quick.application.refresh")
      .accessibilityLabel("刷新应用列表")
      .accessibilityHint("重新扫描应用目录并保留当前搜索")
    }
  }

  private var candidateResults: some View {
    Group {
      if searchController.snapshot.isLoading && unifiedCandidates.isEmpty {
        HStack {
          Spacer()
          ProgressView("正在查找…").controlSize(.small)
          Spacer()
        }
      } else if let failure = searchController.snapshot.failure,
        websiteCandidate == nil
      {
        ContentUnavailableView(
          failure.message,
          systemImage: "app.dashed"
        )
      } else if unifiedCandidates.isEmpty {
        ContentUnavailableView(
          rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "输入应用名称或网址" : "没有匹配结果",
          systemImage: "magnifyingglass"
        )
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 3) {
              ForEach(unifiedCandidates) { candidate in
                candidateRow(candidate)
                  .id(candidate.id)
              }
            }
          }
          .onChange(of: selectedCandidateID) { _, selectedID in
            guard let selectedID else { return }
            withAnimation(.easeOut(duration: 0.12)) {
              proxy.scrollTo(selectedID, anchor: .center)
            }
          }
        }
      }
    }
    .frame(minHeight: 156, maxHeight: 196, alignment: .top)
  }

  private func candidateRow(_ candidate: UnifiedCandidate) -> some View {
    Button {
      selectedCandidateID = candidate.id
      submit(candidate)
    } label: {
      HStack(spacing: 10) {
        candidateIcon(candidate)
          .frame(width: 30, height: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(candidateTitle(candidate))
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          if let detail = candidateDetail(candidate) {
            Text(detail)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer()
        if selectedCandidateID == candidate.id {
          Image(systemName: "return")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .background(
        selectedCandidateID == candidate.id
          ? Color.accentColor.opacity(0.14) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
    }
    .buttonStyle(.plain)
    .disabled(isSubmitting)
    .accessibilityIdentifier("launcher.quick.candidate.\(candidate.id)")
    .accessibilityHint("立即绑定到键位 \(keyLabel)")
  }

  @ViewBuilder
  private func candidateIcon(_ candidate: UnifiedCandidate) -> some View {
    switch candidate {
    case .website(let url):
      DeterministicWebsiteMonogram(url: url)
    case .application(let application, _):
      Image(nsImage: LauncherIconCache.shared.icon(for: application.url))
        .resizable()
        .scaledToFit()
    }
  }

  private func candidateTitle(_ candidate: UnifiedCandidate) -> String {
    switch candidate {
    case .website(let url):
      "打开网站 \(url.host ?? url.absoluteString)"
    case .application(let application, _):
      application.displayName
    }
  }

  private func candidateDetail(_ candidate: UnifiedCandidate) -> String? {
    switch candidate {
    case .website(let url):
      return url.absoluteString
    case .application(let application, _):
      guard shouldDisambiguate(application) else { return nil }
      return application.bundleIdentifier ?? application.url.path
    }
  }

  private var localTargetActions: some View {
    HStack(spacing: 8) {
      localTargetButton("其他应用…", systemImage: "app.badge", kind: .application)
      localTargetButton("文件…", systemImage: "doc", kind: .file)
      localTargetButton("文件夹…", systemImage: "folder", kind: .folder)
    }
  }

  private func localTargetButton(
    _ title: String,
    systemImage: String,
    kind: LaunchTargetKind
  ) -> some View {
    Button {
      chooseLocalTarget(kind)
    } label: {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isSubmitting)
    .focused($focusedControl, equals: focusIntent(for: kind))
    .accessibilityIdentifier("launcher.quick.local.\(kind.rawValue)")
    .accessibilityHint("打开 macOS 选择器；取消后返回当前绑定位置")
  }

  private var shortcutOptions: some View {
    VStack(alignment: .leading, spacing: 11) {
      SlotModifierPicker(
        modifiers: $selectedModifiers,
        keyLabel: keyLabel,
        onChange: {
          shortcutWasCustomized = true
          usesPanelOnly = false
          clearStaleError()
          synchronizeChooserSnapshot()
        }
      )

      Toggle("只在面板内使用", isOn: Binding(
        get: { usesPanelOnly },
        set: { newValue in
          usesPanelOnly = newValue
          shortcutWasCustomized = true
          clearStaleError()
          synchronizeChooserSnapshot()
        }
      ))
      .toggleStyle(.switch)
      .controlSize(.small)
      .accessibilityIdentifier("launcher.quick.panel-only")

      if pendingTarget != nil || isShortcutConflict {
        conflictRecovery
      }
    }
  }

  private var conflictRecovery: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("一键尝试其他组合")
        .font(.caption.weight(.semibold))
      HStack(spacing: 6) {
        ForEach(Array(module.suggestedModifierSets(for: keyCode).prefix(3)), id: \.rawValue) {
          modifiers in
          Button("\(modifiers.displayName)\(keyLabel)") {
            selectedModifiers = modifiers
            usesPanelOnly = false
            shortcutWasCustomized = true
            clearStaleError()
            synchronizeChooserSnapshot()
            retryPendingTarget()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        Button("仅面板") {
          usesPanelOnly = true
          shortcutWasCustomized = true
          clearStaleError()
          synchronizeChooserSnapshot()
          retryPendingTarget()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private var feedback: some View {
    if isSubmitting {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("正在保存…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("launcher.quick.progress")
    } else if let error = inlineError ?? module.errorMessage {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("launcher.quick.error")
    }
  }

  private var footer: some View {
    HStack {
      Button(showsShortcutOptions ? "收起快捷键选项" : "快捷键选项") {
        showsShortcutOptions.toggle()
        clearStaleError()
        synchronizeChooserSnapshot()
      }
      .buttonStyle(.link)
      .disabled(isSubmitting)
      .focused($focusedControl, equals: .shortcutOptions)
      .accessibilityIdentifier("launcher.quick.shortcut-options")
      .accessibilityHint("修改修饰键或改为仅在面板内使用")
      Spacer()
      Text("选择后自动保存")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private var unifiedCandidates: [UnifiedCandidate] {
    var candidates: [UnifiedCandidate] = []
    if let websiteCandidate { candidates.append(.website(websiteCandidate)) }
    candidates.append(contentsOf: searchController.snapshot.candidates.map {
      .application($0, generation: searchController.snapshot.generation)
    })
    return candidates
  }

  private var websiteCandidate: URL? {
    let value = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
      value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }),
      isExplicitWebInput(value)
    else { return nil }
    return try? WebURLValidator.normalize(value)
  }

  private func isExplicitWebInput(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") { return true }
    guard !value.contains("://") else { return false }
    let hostPart = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
    let hostWithoutPort = hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
    guard hostWithoutPort.contains("."), !hostWithoutPort.hasPrefix("."), !hostWithoutPort.hasSuffix(".") else {
      return false
    }
    return hostWithoutPort.split(separator: ".").allSatisfy { label in
      !label.isEmpty && label.allSatisfy { character in
        character.isLetter || character.isNumber || character == "-"
      }
    }
  }

  private func shouldDisambiguate(_ application: ApplicationDescriptor) -> Bool {
    searchController.snapshot.candidates.filter {
      $0.displayName.compare(application.displayName, options: [.caseInsensitive, .diacriticInsensitive])
        == .orderedSame
    }.count > 1
  }

  private var keyLabel: String { module.keyLabel(for: keyCode) }

  private var shortcutSummary: String {
    if usesPanelOnly { return "仅面板" }
    if shortcutWasCustomized { return selectedModifiers.displayName + keyLabel }
    if let current = module.directHotkey(for: keyCode) {
      return module.hotkeyDisplayName(current)
    }
    return ModifierSet.control.displayName + keyLabel
  }

  private var shortcutChoice: QuickBindingShortcutChoice {
    if usesPanelOnly { return .panelOnly }
    if shortcutWasCustomized { return .customModifiers(selectedModifiers) }
    return module.bindingRecord(for: keyCode) == nil ? .defaultForNew : .preserveExisting
  }

  private var pendingTarget: QuickBindingPendingTarget? {
    guard let session = module.quickBindingSession, session.id == sessionID else { return nil }
    return session.pendingTarget
  }

  private var isShortcutConflict: Bool {
    guard let message = inlineError ?? module.errorMessage else { return false }
    return message.contains("占用") || message.contains("冲突")
  }

  private func requestPrimaryFocus() {
    focusedControl = nil
    focusRequestID &+= 1
  }

  private func restoreSavedFocus() {
    let intent = module.quickBindingSession.flatMap {
      $0.id == sessionID ? $0.chooserSnapshot.focusIntent : nil
    } ?? .primaryInput
    switch intent {
    case .applicationAction, .fileAction, .folderAction, .shortcutOptions:
      DispatchQueue.main.async { focusedControl = intent }
    case .primaryInput, .candidateList:
      requestPrimaryFocus()
    }
  }

  private func focusIntent(for kind: LaunchTargetKind) -> QuickBindingFocusIntent {
    switch kind {
    case .application: .applicationAction
    case .file: .fileAction
    case .folder: .folderAction
    case .web: .primaryInput
    }
  }

  private func reconcileSelection() {
    let ids = unifiedCandidates.map(\.id)
    if let selectedCandidateID, ids.contains(selectedCandidateID) { return }
    selectedCandidateID = ids.first
  }

  private func moveSelection(_ direction: ApplicationSearchNavigationDirection) {
    let candidates = unifiedCandidates
    guard !candidates.isEmpty else { return }
    let currentIndex = selectedCandidateID.flatMap { selectedID in
      candidates.firstIndex(where: { $0.id == selectedID })
    }
    let targetIndex: Int
    switch direction {
    case .previous:
      targetIndex = max(0, (currentIndex ?? 0) - 1)
    case .next:
      targetIndex = min(candidates.count - 1, (currentIndex ?? -1) + 1)
    }
    selectedCandidateID = candidates[targetIndex].id
  }

  private func submitSelectedCandidate() {
    guard let selectedCandidateID,
      let candidate = unifiedCandidates.first(where: { $0.id == selectedCandidateID })
    else { return }
    submit(candidate)
  }

  private func submit(_ candidate: UnifiedCandidate) {
    switch candidate {
    case .website(let url):
      guard websiteCandidate == url else { return }
      bind(url: url, kind: .web)
    case .application(let application, let generation):
      let rawID = application.id
      guard searchController.selectCandidate(id: rawID, generation: generation),
        let current = searchController.candidateForSubmission(
          id: rawID,
          generation: generation
        )
      else { return }
      bind(
        url: current.url,
        kind: .application,
        preferredDisplayName: current.displayName
      )
    }
  }

  private func chooseLocalTarget(_ kind: LaunchTargetKind) {
    let selectedShortcutChoice = shortcutChoice
    let focusIntent: QuickBindingFocusIntent
    switch kind {
    case .application: focusIntent = .applicationAction
    case .file: focusIntent = .fileAction
    case .folder: focusIntent = .folderAction
    case .web: focusIntent = .primaryInput
    }
    synchronizeChooserSnapshot(focusIntent: focusIntent)
    isSubmitting = true
    inlineError = nil
    Task { @MainActor in
      defer { isSubmitting = false }
      do {
        guard let url = try await module.selectQuickTarget(
          kind: kind,
          for: keyCode,
          shortcutChoice: selectedShortcutChoice,
          sessionID: sessionID
        ) else {
          return
        }
        let result = try await module.quickBindTarget(
          url: url,
          kind: kind,
          to: keyCode,
          shortcutChoice: selectedShortcutChoice,
          sessionID: sessionID
        )
        handle(result)
      } catch {
        inlineError = error.localizedDescription
      }
    }
  }

  private func bind(
    url: URL,
    kind: LaunchTargetKind,
    preferredDisplayName: String? = nil
  ) {
    let selectedShortcutChoice = shortcutChoice
    synchronizeChooserSnapshot()
    isSubmitting = true
    inlineError = nil
    Task { @MainActor in
      defer { isSubmitting = false }
      do {
        let result = try await module.quickBindTarget(
          url: url,
          kind: kind,
          to: keyCode,
          shortcutChoice: selectedShortcutChoice,
          preferredDisplayName: preferredDisplayName,
          sessionID: sessionID
        )
        handle(result)
      } catch {
        inlineError = error.localizedDescription
      }
    }
  }

  private func retryPendingTarget() {
    guard let pendingTarget else { return }
    bind(
      url: pendingTarget.url,
      kind: pendingTarget.kind,
      preferredDisplayName: pendingTarget.preferredDisplayName
    )
  }

  private func clearStaleError() {
    inlineError = nil
    module.errorMessage = nil
  }

  private func synchronizeChooserSnapshot(
    focusIntent: QuickBindingFocusIntent = .primaryInput
  ) {
    module.updateQuickBindingChooserSnapshot(
      QuickBindingChooserSnapshot(
        rawInput: rawInput,
        selectedCandidateID: selectedCandidateID,
        focusIntent: focusIntent,
        showsShortcutOptions: showsShortcutOptions,
        selectedModifiers: selectedModifiers,
        usesPanelOnly: usesPanelOnly,
        shortcutWasCustomized: shortcutWasCustomized
      ),
      sessionID: sessionID
    )
  }

  private func handle(_ result: LauncherCommitResult) {
    switch result {
    case .committed:
      if module.quickBindingSession?.id == sessionID, let error = module.errorMessage {
        inlineError = error
        showsShortcutOptions = true
      } else {
        inlineError = nil
      }
    case .rejected(.noChanges):
      inlineError = nil
    case .registrationFailed(_, let combination):
      inlineError = "\(combination.displayName) 已被占用；原绑定保持不变。请选择一个建议组合。"
      showsShortcutOptions = true
    case .validationFailed(let issues):
      inlineError = module.errorMessage ?? "这个目标或快捷键无法保存；原绑定保持不变。"
      if issues.contains(where: {
        $0.code == .invalidHotkey
          || $0.code == .duplicateHotkey
          || $0.code == .panelHotkeyConflict
      }) {
        showsShortcutOptions = true
      }
    case .persistenceFailed:
      inlineError = "保存失败，原绑定没有改变；请重试。"
    case .rejected(.staleRevision):
      inlineError = module.errorMessage ?? "配置刚刚发生变化；目标已保留，请确认后重试。"
      showsShortcutOptions = pendingTarget != nil
    case .rejected:
      inlineError = module.errorMessage ?? "当前无法保存；原绑定没有改变，请稍后重试。"
    }
    synchronizeChooserSnapshot()
  }
}
