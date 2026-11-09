import Darwin
import Foundation

/// Deletes the one PNG that cmux leaves behind for each `browser.screenshot`.
///
/// cmux reports paths such as `/var/folders/.../T/cmux-browser-screenshots/surface-....png`,
/// while the real path starts with `/private/var`. A path is deleted only when its parent
/// resolves to exactly `<realpath(temporary directory)>/cmux-browser-screenshots`, it has no
/// `.` or `..` component, its name is `surface-*.png`, and it is a regular file. Anything
/// else is left alone. Outcomes carry no path, so they are safe to log.
struct BrowserScreenshotCleanup: Sendable {
    enum Refusal: String, Sendable, Equatable {
        case notAbsolute = "not_absolute"
        case dotComponent = "dot_component"
        case namePrefix = "name_prefix"
        case nameSuffix = "name_suffix"
        case outsideDirectory = "outside_directory"
        case notRegularFile = "not_regular_file"
        case baseUnavailable = "base_unavailable"
    }

    enum Outcome: Sendable, Equatable {
        case deleted
        case missing
        case refused(Refusal)
        case unlinkFailed(errno: Int32)
    }

    static let directoryName = "cmux-browser-screenshots"
    static let namePrefix = "surface-"
    static let nameSuffix = ".png"

    let baseDirectory: String?

    init(temporaryDirectory: String = NSTemporaryDirectory()) {
        baseDirectory = Self.resolvedPath(temporaryDirectory).map { "\($0)/\(Self.directoryName)" }
    }

    func remove(path: String) -> Outcome {
        guard path.hasPrefix("/") else { return .refused(.notAbsolute) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return .refused(.dotComponent)
        }
        let name = String(components.last ?? "")
        guard name.hasPrefix(Self.namePrefix) else { return .refused(.namePrefix) }
        guard name.hasSuffix(Self.nameSuffix) else { return .refused(.nameSuffix) }
        guard let baseDirectory else { return .refused(.baseUnavailable) }
        let parent = "/" + components.dropLast().joined(separator: "/")
        guard Self.resolvedPath(parent) == baseDirectory else { return .refused(.outsideDirectory) }

        let directory = open(baseDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return .refused(.baseUnavailable) }
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .missing : .unlinkFailed(errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .refused(.notRegularFile) }
        guard unlinkat(directory, name, 0) == 0 else {
            return errno == ENOENT ? .missing : .unlinkFailed(errno: errno)
        }
        return .deleted
    }

    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
