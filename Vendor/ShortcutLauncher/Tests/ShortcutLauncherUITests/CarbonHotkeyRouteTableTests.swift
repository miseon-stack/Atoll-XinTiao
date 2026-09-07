import ShortcutLauncherCore
@testable import ShortcutLauncherUI
import XCTest

final class CarbonHotkeyRouteTableTests: XCTestCase {
  func testCarbonEventOwnershipRequiresSignatureAndKnownSystemID() {
    let table = CarbonHotkeyRouteTable()
    table.install(systemID: 1, id: .panel)

    XCTAssertNil(captureShortcutLauncherCarbonDelivery(
      signature: 0x4F54_4845,
      systemID: 1,
      capture: table.capture(systemID:)
    ))
    XCTAssertNil(captureShortcutLauncherCarbonDelivery(
      signature: shortcutLauncherCarbonSignature,
      systemID: 99,
      capture: table.capture(systemID:)
    ))
    XCTAssertEqual(
      captureShortcutLauncherCarbonDelivery(
        signature: shortcutLauncherCarbonSignature,
        systemID: 1,
        capture: table.capture(systemID:)
      )?.id,
      .panel
    )
  }

  @MainActor
  func testRegistrarDeliveryRejectsSnapshotInvalidatedBeforeMainActorDispatch() throws {
    let table = CarbonHotkeyRouteTable()
    let registrar = CarbonHotkeyRegistrar(routeTable: table)
    let recorder = CarbonDeliveryRecorder()
    let oldID = HotkeyID.direct(bindingID: BindingID(rawValue: "component-old"))
    let newID = HotkeyID.direct(bindingID: BindingID(rawValue: "component-new"))
    registrar.setHandler { recorder.ids.append($0) }
    table.install(systemID: 11, id: oldID)
    let queuedDelivery = try XCTUnwrap(registrar.captureDelivery(systemID: 11))

    table.commit([11: newID])
    registrar.deliver(queuedDelivery)

    XCTAssertTrue(recorder.ids.isEmpty)
    registrar.deliver(try XCTUnwrap(registrar.captureDelivery(systemID: 11)))
    XCTAssertEqual(recorder.ids, [newID])
  }

  func testQueuedEventIsDiscardedWhenCommitReassignsItsSystemID() throws {
    let table = CarbonHotkeyRouteTable()
    let oldID = HotkeyID.direct(bindingID: BindingID(rawValue: "old-binding"))
    let newID = HotkeyID.direct(bindingID: BindingID(rawValue: "new-binding"))
    table.install(systemID: 17, id: oldID)
    let queuedBeforeCommit = try XCTUnwrap(table.capture(systemID: 17))

    table.commit([17: newID])

    XCTAssertNil(table.resolve(queuedBeforeCommit))
    let arrivedAfterCommit = try XCTUnwrap(table.capture(systemID: 17))
    XCTAssertEqual(table.resolve(arrivedAfterCommit), newID)
  }

  func testQueuedStagingEventCannotBecomeFinalBindingAfterCommit() throws {
    let table = CarbonHotkeyRouteTable()
    let stagingID = HotkeyID.direct(
      bindingID: BindingID(rawValue: "__shortcut_launcher_stage_fixture")
    )
    let finalID = HotkeyID.direct(bindingID: BindingID(rawValue: "final-binding"))
    table.install(systemID: 23, id: stagingID)
    let queuedWhileSaveWasPending = try XCTUnwrap(table.capture(systemID: 23))

    table.commit([23: finalID])

    XCTAssertNil(table.resolve(queuedWhileSaveWasPending))
    XCTAssertEqual(table.resolve(try XCTUnwrap(table.capture(systemID: 23))), finalID)
  }

  func testQueuedEventsCannotCrossRouteDuringTwoWaySwap() throws {
    let table = CarbonHotkeyRouteTable()
    let firstID = HotkeyID.direct(bindingID: BindingID(rawValue: "swap-first"))
    let secondID = HotkeyID.direct(bindingID: BindingID(rawValue: "swap-second"))
    table.install(systemID: 61, id: firstID)
    table.install(systemID: 62, id: secondID)
    let queuedFirst = try XCTUnwrap(table.capture(systemID: 61))
    let queuedSecond = try XCTUnwrap(table.capture(systemID: 62))

    table.commit([61: secondID, 62: firstID])

    XCTAssertNil(table.resolve(queuedFirst))
    XCTAssertNil(table.resolve(queuedSecond))
    XCTAssertEqual(table.resolve(try XCTUnwrap(table.capture(systemID: 61))), secondID)
    XCTAssertEqual(table.resolve(try XCTUnwrap(table.capture(systemID: 62))), firstID)
  }

  func testRemovingFailedStagingRoutePreservesQueuedCommittedEvent() throws {
    let table = CarbonHotkeyRouteTable()
    let committedID = HotkeyID.direct(bindingID: BindingID(rawValue: "rollback-committed"))
    let stagingID = HotkeyID.direct(bindingID: BindingID(rawValue: "rollback-staging"))
    table.install(systemID: 71, id: committedID)
    table.install(systemID: 72, id: stagingID)
    let queuedCommitted = try XCTUnwrap(table.capture(systemID: 71))
    let queuedStaging = try XCTUnwrap(table.capture(systemID: 72))

    table.remove(systemID: 72)

    XCTAssertEqual(table.resolve(queuedCommitted), committedID)
    XCTAssertNil(table.resolve(queuedStaging))
  }

  func testEveryCommitInvalidatesQueuedEventsEvenWhenLogicalRouteIsUnchanged() throws {
    let table = CarbonHotkeyRouteTable()
    let bindingID = HotkeyID.direct(bindingID: BindingID(rawValue: "unchanged-binding"))
    table.install(systemID: 31, id: bindingID)
    let queuedAgainstOldConfiguration = try XCTUnwrap(table.capture(systemID: 31))

    table.commit([31: bindingID])

    XCTAssertNil(table.resolve(queuedAgainstOldConfiguration))
    XCTAssertEqual(table.resolve(try XCTUnwrap(table.capture(systemID: 31))), bindingID)
  }

  func testShutdownInvalidatesQueuedEventAcrossSystemIDReuse() throws {
    let table = CarbonHotkeyRouteTable()
    let bindingID = HotkeyID.direct(bindingID: BindingID(rawValue: "restart-binding"))
    table.install(systemID: 41, id: bindingID)
    let queuedBeforeShutdown = try XCTUnwrap(table.capture(systemID: 41))

    table.shutdown()
    table.install(systemID: 41, id: bindingID)

    XCTAssertNil(table.resolve(queuedBeforeShutdown))
    XCTAssertEqual(table.resolve(try XCTUnwrap(table.capture(systemID: 41))), bindingID)
  }

  func testAddingStagingRouteDoesNotInvalidateQueuedCommittedRoute() throws {
    let table = CarbonHotkeyRouteTable()
    let committedID = HotkeyID.direct(bindingID: BindingID(rawValue: "committed-binding"))
    let stagingID = HotkeyID.direct(bindingID: BindingID(rawValue: "staging-binding"))
    table.install(systemID: 51, id: committedID)
    let queuedCommittedEvent = try XCTUnwrap(table.capture(systemID: 51))

    table.install(systemID: 52, id: stagingID)

    XCTAssertEqual(table.resolve(queuedCommittedEvent), committedID)
  }
}

@MainActor
private final class CarbonDeliveryRecorder {
  var ids: [HotkeyID] = []
}
