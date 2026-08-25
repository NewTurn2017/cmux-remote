/// Identifies a terminal grid lifetime across full, clear, reset, and surface changes.
struct TerminalGridEpoch: Equatable, Comparable, Sendable {
    static let initial = TerminalGridEpoch(validatedRawValue: 0)

    let rawValue: Int

    init?(rawValue: Int) {
        guard rawValue >= 0 else { return nil }
        self.rawValue = rawValue
    }

    static func < (lhs: TerminalGridEpoch, rhs: TerminalGridEpoch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private init(validatedRawValue: Int) {
        self.rawValue = validatedRawValue
    }
}
