import Foundation

@MainActor
public final class HotkeyLifecycle {
  public enum State: Equatable, Sendable {
    case stopped
    case started
  }

  public private(set) var state: State = .stopped
  private let registrar: any HotkeyRegistering

  public init(registrar: any HotkeyRegistering) {
    self.registrar = registrar
  }

  public func start(
    panelHotkey: HotkeyDefinition,
    handler: @escaping @MainActor @Sendable (HotkeyID) -> Void
  ) async throws {
    guard state == .stopped else { return }

    try panelHotkey.validate()
    registrar.setHandler(handler)

    do {
      try await registrar.register(panelHotkey, id: .panel)
      state = .started
    } catch {
      await registrar.shutdown()
      throw error
    }
  }

  public func stop() async {
    guard state == .started else { return }
    await registrar.shutdown()
    state = .stopped
  }
}
