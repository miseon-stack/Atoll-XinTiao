import ShortcutLauncherCore
import SwiftUI

public enum LauncherFeedbackKind: String, Equatable, Sendable {
  case success
  case information
  case warning
  case error
}

public struct LauncherUndoToken: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let before: LauncherConfiguration
  public let expectedAfterRevision: UInt64
  public let slotKeyCode: UInt16?

  public init(
    id: UUID = UUID(),
    before: LauncherConfiguration,
    expectedAfterRevision: UInt64,
    slotKeyCode: UInt16?
  ) {
    self.id = id
    self.before = before
    self.expectedAfterRevision = expectedAfterRevision
    self.slotKeyCode = slotKeyCode
  }
}

public struct LauncherFeedbackEvent: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let kind: LauncherFeedbackKind
  public let message: String
  public let slotKeyCode: UInt16?
  public let undoToken: LauncherUndoToken?

  public init(
    id: UUID = UUID(),
    kind: LauncherFeedbackKind,
    message: String,
    slotKeyCode: UInt16? = nil,
    undoToken: LauncherUndoToken? = nil
  ) {
    self.id = id
    self.kind = kind
    self.message = message
    self.slotKeyCode = slotKeyCode
    self.undoToken = undoToken
  }
}

struct LauncherToast: View {
  let event: LauncherFeedbackEvent
  let undo: (() -> Void)?
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbolName)
        .foregroundStyle(tint)
      Text(event.message)
        .font(.subheadline.weight(.medium))
        .lineLimit(2)
      Spacer(minLength: 8)
      if event.undoToken != nil, let undo {
        Button("撤销", action: undo)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("launcher.toast.undo")
          .accessibilityHint("恢复这次操作前的绑定和快捷键")
      }
      Button(action: dismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("关闭提示")
      .accessibilityIdentifier("launcher.toast.dismiss")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(tint.opacity(0.35), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("launcher.toast")
  }

  private var symbolName: String {
    switch event.kind {
    case .success: "checkmark.circle.fill"
    case .information: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }

  private var tint: Color {
    switch event.kind {
    case .success: .green
    case .information: .accentColor
    case .warning: .orange
    case .error: .red
    }
  }
}
