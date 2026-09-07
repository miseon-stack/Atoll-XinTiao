import Foundation

/// Coordinates ownership of process-wide hotkey resources.
///
/// Production hosts share ``processShared`` so only one launcher instance can
/// receive global hotkey events. Tests and preview hosts can inject an isolated
/// instance without leaking ownership between cases.
@MainActor
public final class HotkeyOwnerLease {
  public static let processShared = HotkeyOwnerLease()

  private var ownerToken: UUID?

  public init() {}

  @discardableResult
  public func acquire(token: UUID) -> Bool {
    if ownerToken == token { return true }
    guard ownerToken == nil else { return false }
    ownerToken = token
    return true
  }

  public func release(token: UUID) {
    guard ownerToken == token else { return }
    ownerToken = nil
  }

  public func isOwned(by token: UUID) -> Bool {
    ownerToken == token
  }
}
