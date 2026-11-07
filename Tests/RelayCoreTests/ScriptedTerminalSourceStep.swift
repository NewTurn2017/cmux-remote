import CMUXClient
import Foundation

enum ScriptedTerminalSourceStep: Sendable {
    case immediate(CMUXTerminalReadOutcome)
    case failure(String)
    case notTerminal
    case suspended(CMUXTerminalReadOutcome)
}
