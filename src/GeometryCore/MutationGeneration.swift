import Foundation

struct MutationGeneration: Equatable, Sendable {
    private(set) var value: UInt64
    private(set) var overflowIdentity: UUID

    init(value: UInt64 = 0, overflowIdentity: UUID = UUID()) {
        self.value = value
        self.overflowIdentity = overflowIdentity
    }

    mutating func advance() {
        if value == .max {
            overflowIdentity = UUID()
        } else {
            value += 1
        }
    }

    func isNotNewer(than other: MutationGeneration) -> Bool {
        // Different overflow identities are unrelated lineages. Treating either as
        // older could delete a Recovery snapshot whose ordering is unknown.
        guard overflowIdentity == other.overflowIdentity else { return false }
        return value <= other.value
    }
}
