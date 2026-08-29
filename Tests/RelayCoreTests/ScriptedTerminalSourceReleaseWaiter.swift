import Foundation

struct ScriptedTerminalSourceReleaseWaiter {
    let continuation: CheckedContinuation<Void, Never>
}
