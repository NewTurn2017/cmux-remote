import Foundation

struct TerminalArtifactPartialWrite: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}
