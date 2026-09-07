import Foundation

public struct KeySlotDefinition: Hashable, Identifiable, Sendable {
  public var id: UInt16 { keyCode }
  public let keyCode: UInt16
  public let fallbackLabel: String
  public let row: Int
  public let column: Int

  public init(keyCode: UInt16, fallbackLabel: String, row: Int, column: Int) {
    self.keyCode = keyCode
    self.fallbackLabel = fallbackLabel
    self.row = row
    self.column = column
  }
}

public enum KeySlotCatalog {
  public static let rows: [[KeySlotDefinition]] = [
    makeRow(
      row: 0,
      values: [
        (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"),
        (26, "7"), (28, "8"), (25, "9"), (29, "0"), (27, "-"), (24, "="),
      ]
    ),
    makeRow(
      row: 1,
      values: [
        (12, "Q"), (13, "W"), (14, "E"), (15, "R"), (17, "T"),
        (16, "Y"), (32, "U"), (34, "I"), (31, "O"), (35, "P"),
      ]
    ),
    makeRow(
      row: 2,
      values: [
        (0, "A"), (1, "S"), (2, "D"), (3, "F"), (5, "G"),
        (4, "H"), (38, "J"), (40, "K"), (37, "L"),
      ]
    ),
    makeRow(
      row: 3,
      values: [
        (6, "Z"), (7, "X"), (8, "C"), (9, "V"),
        (11, "B"), (45, "N"), (46, "M"),
      ]
    ),
  ]

  public static let all = rows.flatMap { $0 }
  public static let allowedKeyCodes = Set(all.map(\.keyCode))

  public static func definition(for keyCode: UInt16) -> KeySlotDefinition? {
    all.first { $0.keyCode == keyCode }
  }

  public static func label(for keyCode: UInt16) -> String {
    definition(for: keyCode)?.fallbackLabel ?? "?"
  }

  private static func makeRow(
    row: Int,
    values: [(UInt16, String)]
  ) -> [KeySlotDefinition] {
    values.enumerated().map { index, value in
      KeySlotDefinition(
        keyCode: value.0,
        fallbackLabel: value.1,
        row: row,
        column: index
      )
    }
  }
}
