import Foundation
import SharedKit

public struct HostBatterySnapshot: Equatable, Sendable {
    public let available: Bool
    public let percent: Int?
    public let state: String?
    public let powerSource: String?

    public var isCharging: Bool? {
        guard let state else { return nil }
        return state == "charging" || state == "charged" || state == "finishing charge"
    }

    public var json: JSONValue {
        .object([
            "available": .bool(available),
            "percent": percent.map { .int(Int64($0)) } ?? .null,
            "state": state.map { .string($0) } ?? .null,
            "is_charging": isCharging.map { .bool($0) } ?? .null,
            "power_source": powerSource.map { .string($0) } ?? .null,
        ])
    }
}

public enum HostBatteryService {
    public static func snapshot() -> HostBatterySnapshot {
        let output = runPMSet()
        return parse(pmsetOutput: output)
    }

    public static func parse(pmsetOutput output: String) -> HostBatterySnapshot {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let powerSource = lines.first.flatMap { line -> String? in
            guard let start = line.firstIndex(of: "'"),
                  let end = line[line.index(after: start)...].firstIndex(of: "'")
            else { return nil }
            return String(line[line.index(after: start)..<end])
        }

        guard let batteryLine = lines.first(where: { $0.contains("%") }) else {
            return HostBatterySnapshot(available: false, percent: nil, state: nil, powerSource: powerSource)
        }

        let parts = batteryLine.split(separator: ";", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let percent = parts.first.flatMap { part -> Int? in
            guard let range = part.range(of: #"\d+(?=%)"#, options: .regularExpression) else { return nil }
            return Int(part[range])
        }
        let state = parts.dropFirst().first?.lowercased()
        return HostBatterySnapshot(available: percent != nil, percent: percent, state: state, powerSource: powerSource)
    }

    private static func runPMSet() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

public struct UploadedFileResult: Equatable, Sendable {
    public let filename: String
    public let path: String
    public let bytes: Int
    public let mimeType: String

    public var json: JSONValue {
        .object([
            "filename": .string(filename),
            "path": .string(path),
            "bytes": .int(Int64(bytes)),
            "mime_type": .string(mimeType),
        ])
    }
}

public enum RelayFileUploadError: Error, CustomStringConvertible, Equatable {
    case invalidParams
    case invalidBase64
    case tooLarge(Int)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .invalidParams:
            return "file.upload requires filename, mime_type, and data_base64"
        case .invalidBase64:
            return "file.upload data_base64 is not valid base64"
        case .tooLarge(let limit):
            return "file.upload exceeds \(limit) bytes"
        case .writeFailed(let message):
            return "file.upload write failed: \(message)"
        }
    }
}

public enum RelayFileUploadService {
    public static let maxBytes = 12 * 1024 * 1024

    public static func save(
        params: JSONValue,
        date: Date = Date(),
        directory overrideDirectory: URL? = nil
    ) throws -> UploadedFileResult {
        guard case .object(let object) = params,
              case .string(let requestedFilename)? = object["filename"],
              case .string(let mimeType)? = object["mime_type"] ?? object["mimeType"],
              case .string(let base64)? = object["data_base64"] ?? object["dataBase64"]
        else { throw RelayFileUploadError.invalidParams }
        guard let data = Data(base64Encoded: base64) else { throw RelayFileUploadError.invalidBase64 }
        guard data.count <= maxBytes else { throw RelayFileUploadError.tooLarge(maxBytes) }

        let directory = overrideDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
                .appendingPathComponent("cmux-remote", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = uniqueFilename(requestedFilename, mimeType: mimeType, date: date)
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            try data.write(to: url, options: .atomic)
            return UploadedFileResult(filename: filename, path: url.path, bytes: data.count, mimeType: mimeType)
        } catch let error as RelayFileUploadError {
            throw error
        } catch {
            throw RelayFileUploadError.writeFailed(String(describing: error))
        }
    }

    private static func uniqueFilename(_ requested: String, mimeType: String, date: Date) -> String {
        let safeBase = sanitize(requested)
        let ext = fileExtension(for: mimeType)
        let base: String
        if safeBase.isEmpty {
            base = "iphone-image.\(ext)"
        } else if (safeBase as NSString).pathExtension.isEmpty {
            base = safeBase + ".\(ext)"
        } else {
            base = safeBase
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(base)"
    }

    private static func sanitize(_ name: String) -> String {
        let last = URL(fileURLWithPath: name).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return last.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce(into: "") { $0.append($1) }
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        default: return "jpg"
        }
    }
}
