import Foundation
import IOSSecuritySuite

public enum HardeningResult: Equatable {
    case ok
    case failedJailbroken
    case failedDebugged
}

public final class HardeningCheck {
    private let jailbroken: () -> Bool
    private let debugged: () -> Bool
    private let keychain: Keychain

    public init(jailbroken: @escaping () -> Bool = { IOSSecuritySuite.amIJailbroken() },
                debugged: @escaping () -> Bool = { IOSSecuritySuite.amIDebugged() },
                keychain: Keychain)
    {
        self.jailbroken = jailbroken
        self.debugged = debugged
        self.keychain = keychain
    }

    @discardableResult
    public func runAtLaunch() -> HardeningResult {
        if jailbroken() {
            try? keychain.wipe()
            return .failedJailbroken
        }
        if debugged() {
            try? keychain.wipe()
            return .failedDebugged
        }
        return .ok
    }
}
