import CMUXClient
import Foundation

struct ScriptedSuspendedTerminalRead {
    let outcome: CMUXTerminalReadOutcome
    let continuation: CheckedContinuation<CMUXTerminalReadOutcome, Error>
}
