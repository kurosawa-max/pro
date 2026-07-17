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
        guard overflowIdentity == other.overflowIdentity else { return self == other }
        return value <= other.value
    }
}
