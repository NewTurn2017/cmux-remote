import Foundation

actor FoundationTerminalArtifactFileMetadata: TerminalArtifactFileMetadataApplying {
    private let fileManager: FileManager

    init(fileManager: FileManager = FileManager()) {
        self.fileManager = fileManager
    }

    func secure(_ url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var secured = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try secured.setResourceValues(values)
    }
}
