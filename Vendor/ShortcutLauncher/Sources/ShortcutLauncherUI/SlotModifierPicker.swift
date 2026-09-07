import ShortcutLauncherCore
import SwiftUI

/// Edits only modifier keys. The primary key is the already-selected panel
/// slot, eliminating the duplicate-key recording step from the normal flow.
struct SlotModifierPicker: View {
  @Binding var modifiers: ModifierSet
  let keyLabel: String
  var onChange: (() -> Void)?

  private let choices: [(ModifierSet, String, String)] = [
    (.control, "⌃", "Control"),
    (.option, "⌥", "Option"),
    (.command, "⌘", "Command"),
    (.shift, "⇧", "Shift"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("快捷键")
          .font(.caption.weight(.semibold))
        Spacer()
        Text("\(modifiers.displayName)\(keyLabel)")
          .font(.system(.caption, design: .monospaced).weight(.semibold))
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        ForEach(choices, id: \.1) { modifier, glyph, name in
          let isSelected = modifiers.contains(modifier)
          Button {
            toggle(modifier)
          } label: {
            Text(glyph)
              .font(.system(size: 16, weight: .semibold, design: .rounded))
              .frame(maxWidth: .infinity, minHeight: 30)
              .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .stroke(
                    isSelected ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.16),
                    lineWidth: 1
                  )
              }
          }
          .buttonStyle(.plain)
          .help(name)
          .accessibilityIdentifier("launcher.quick.modifier.\(name.lowercased())")
          .accessibilityLabel(name)
          .accessibilityValue(isSelected ? "已选择" : "未选择")
          .disabled(modifier == .shift && baseModifiers.isEmpty)
        }
      }

      Text("主键固定为 \(keyLabel)，不需要再按一次。")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private var baseModifiers: ModifierSet {
    modifiers.intersection([.control, .option, .command])
  }

  private func toggle(_ modifier: ModifierSet) {
    var candidate = modifiers
    if candidate.contains(modifier) {
      candidate.remove(modifier)
    } else {
      candidate.insert(modifier)
    }
    guard !candidate.isEmpty, candidate != .shift else { return }
    modifiers = candidate
    onChange?()
  }
}
