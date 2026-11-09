import Darwin
import Foundation

/// Opens a Claude transcript file only when it is a regular `.jsonl` file inside the allowed root.
///
/// The root is the real path of `~/.claude/projects`. A vault path may go through a symlink that
/// resolves inside the root (the `~/.claude-profiles/*/projects` links do); anything that resolves
/// outside it is refused. Opening walks from the root one component at a time with `O_NOFOLLOW`
/// and checks the leaf with `fstatat` before opening it, so a FIFO or device is never opened.
enum ClaudeTranscriptFileOpener {
    enum Refusal: String, Error, Sendable, Equatable {
        case badPath = "bad_path"
        case notJSONL = "not_jsonl"
        case missing
        case outsideRoot = "outside_root"
        case notRegularFile = "not_regular_file"
    }

    struct OpenedFile: Sendable {
        let descriptor: Int32
        let size: Int64
    }

    /// Most path components below the root: `<encoded cwd>/<session id>.jsonl`.
    static let maxDepthBelowRoot = 2

    static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        realPath(home.appendingPathComponent(".claude/projects", isDirectory: true).path)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func allowedRealPath(_ path: String, root: String) -> Result<String, Refusal> {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return .failure(.badPath) }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return .failure(.badPath) }
        guard path.hasSuffix(".jsonl") else { return .failure(.notJSONL) }
        guard let resolved = realPath(path) else { return .failure(.missing) }
        guard let relative = relativeComponents(of: resolved, root: root) else { return .failure(.outsideRoot) }
        guard resolved.hasSuffix(".jsonl"), let leaf = relative.last, leaf != ".jsonl" else { return .failure(.notJSONL) }
        var status = Darwin.stat()
        guard lstatRetryingEINTR(resolved, &status) == 0 else { return .failure(.missing) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        return .success(resolved)
    }

    static func open(_ path: String, root: String) -> Result<OpenedFile, Refusal> {
        let resolved: String
        switch allowedRealPath(path, root: root) {
        case .success(let value): resolved = value
        case .failure(let refusal): return .failure(refusal)
        }
        guard let relative = relativeComponents(of: resolved, root: root) else { return .failure(.outsideRoot) }

        var directory = openRetryingEINTR(directory: nil, component: root, flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { return .failure(.missing) }
        defer { _ = Darwin.close(directory) }
        for component in relative.dropLast() {
            let next = openRetryingEINTR(directory: directory, component: component, flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { return .failure(.outsideRoot) }
            _ = Darwin.close(directory)
            directory = next
        }

        let leaf = relative[relative.count - 1]
        var entryStatus = Darwin.stat()
        let entryResult = leaf.withCString { fstatatRetryingEINTR(directory, $0, &entryStatus, AT_SYMLINK_NOFOLLOW) }
        guard entryResult == 0 else { return .failure(.missing) }
        guard (entryStatus.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }

        let descriptor = openRetryingEINTR(
            directory: directory, component: leaf, flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return .failure(.missing) }
        var openedStatus = Darwin.stat()
        guard fstatRetryingEINTR(descriptor, &openedStatus) == 0,
              (openedStatus.st_mode & S_IFMT) == S_IFREG,
              openedStatus.st_dev == entryStatus.st_dev, openedStatus.st_ino == entryStatus.st_ino
        else {
            _ = Darwin.close(descriptor)
            return .failure(.notRegularFile)
        }
        return .success(OpenedFile(descriptor: descriptor, size: Int64(openedStatus.st_size)))
    }

    private static func relativeComponents(of resolved: String, root: String) -> [String]? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard resolved.hasPrefix(prefix) else { return nil }
        let relative = resolved.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard (1...maxDepthBelowRoot).contains(relative.count) else { return nil }
        return relative
    }

    private static func openRetryingEINTR(directory: Int32?, component: String, flags: Int32) -> Int32 {
        var result: Int32
        repeat {
            result = component.withCString {
                if let directory { return Darwin.openat(directory, $0, flags) }
                return Darwin.open($0, flags)
            }
        } while result < 0 && errno == EINTR
        return result
    }

    private static func fstatRetryingEINTR(_ descriptor: Int32, _ status: inout Darwin.stat) -> Int32 {
        var result: Int32
        repeat { result = Darwin.fstat(descriptor, &status) } while result < 0 && errno == EINTR
        return result
    }

    private static func lstatRetryingEINTR(_ path: String, _ status: inout Darwin.stat) -> Int32 {
        var result: Int32
        repeat { result = Darwin.lstat(path, &status) } while result < 0 && errno == EINTR
        return result
    }

    private static func fstatatRetryingEINTR(
        _ directory: Int32, _ component: UnsafePointer<CChar>, _ status: inout Darwin.stat, _ flags: Int32
    ) -> Int32 {
        var result: Int32
        repeat { result = Darwin.fstatat(directory, component, &status, flags) } while result < 0 && errno == EINTR
        return result
    }
}
