import Foundation

/// The cmux Remote release version shared by the relay and the iOS app.
///
/// `cmux-relay --version` and `relay.info` report ``marketing``. A SharedKit test keeps it equal to every
/// `CFBundleShortVersionString` in `ios/project.yml`, so bump both together.
public enum CmuxRemoteVersion {
    /// The marketing version: three dot-separated integers, such as `2.0.0`.
    public static let marketing = "2.0.0"
}
