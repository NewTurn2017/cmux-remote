import CMUXClient
import Foundation

enum ScriptedTerminalSourceStep: Sendable {
    case immediate(CMUXTerminalReadOutcome)
    case failure(String)
    case suspended(CMUXTerminalReadOutcome)
}
