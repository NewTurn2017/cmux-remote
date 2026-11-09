import Darwin
import Foundation
import Testing
@testable import RelayServer

@Suite("BrowserScreenshotCleanupTests")
struct BrowserScreenshotCleanupTests {
    @Test func deletesTheScreenshotWhenCmuxReportsTheVarPath() throws {
        let directory = try BrowserScreenshotDirectory()
        let path = try directory.makeFile(directory.screenshots + "/surface-67DA7B9E-1.png")

        #expect(directory.resolvedRoot != directory.root)
        #expect(path.hasPrefix(directory.root))
        #expect(directory.cleanup.remove(path: path) == .deleted)
        #expect(!directory.exists(path))
    }

    @Test func deletesTheScreenshotWhenCmuxReportsTheResolvedPath() throws {
        let directory = try BrowserScreenshotDirectory()
        try directory.makeFile(directory.screenshots + "/surface-67DA7B9E-2.png")
        let resolved = directory.resolvedRoot + "/cmux-browser-screenshots/surface-67DA7B9E-2.png"

        #expect(directory.cleanup.remove(path: resolved) == .deleted)
        #expect(!directory.exists(resolved))
    }

    @Test func leavesFilesThatBreakAPathRule() throws {
        let directory = try BrowserScreenshotDirectory()
        let base = directory.screenshots
        let otherDirectory = try directory.makeFile(directory.root + "/other/surface-a.png")
        let nested = try directory.makeFile(base + "/nested/surface-b.png")
        let wrongPrefix = try directory.makeFile(base + "/shot-c.png")
        let wrongSuffix = try directory.makeFile(base + "/surface-d.jpg")
        let viaParent = try directory.makeFile(base + "/surface-e.png")
        let viaDot = try directory.makeFile(base + "/surface-f.png")
        let cleanup = directory.cleanup

        #expect(cleanup.remove(path: otherDirectory) == .refused(.outsideDirectory))
        #expect(cleanup.remove(path: nested) == .refused(.outsideDirectory))
        #expect(cleanup.remove(path: wrongPrefix) == .refused(.namePrefix))
        #expect(cleanup.remove(path: wrongSuffix) == .refused(.nameSuffix))
        #expect(cleanup.remove(path: base + "/../cmux-browser-screenshots/surface-e.png") == .refused(.dotComponent))
        #expect(cleanup.remove(path: base + "/./surface-f.png") == .refused(.dotComponent))
        #expect(cleanup.remove(path: base + "//surface-f.png") == .refused(.dotComponent))
        #expect(cleanup.remove(path: "cmux-browser-screenshots/surface-f.png") == .refused(.notAbsolute))
        #expect(cleanup.remove(path: base + "/") == .refused(.dotComponent))
        for path in [otherDirectory, nested, wrongPrefix, wrongSuffix, viaParent, viaDot] {
            #expect(directory.exists(path))
        }
    }

    @Test func leavesSymlinksAndTheirTargets() throws {
        let directory = try BrowserScreenshotDirectory()
        let target = try directory.makeFile(directory.root + "/target.png")
        let link = directory.screenshots + "/surface-link.png"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        #expect(directory.cleanup.remove(path: link) == .refused(.notRegularFile))
        #expect(directory.exists(link))
        #expect(directory.exists(target))
    }

    @Test func leavesADirectoryNamedLikeAScreenshot() throws {
        let directory = try BrowserScreenshotDirectory()
        let folder = directory.screenshots + "/surface-folder.png"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)

        #expect(directory.cleanup.remove(path: folder) == .refused(.notRegularFile))
        #expect(directory.exists(folder))
    }

    @Test func refusesWhenTheScreenshotDirectoryIsASymlink() throws {
        let directory = try BrowserScreenshotDirectory()
        let elsewhere = directory.root + "/elsewhere"
        let file = try directory.makeFile(elsewhere + "/surface-g.png")
        let linkedRoot = directory.root + "/linked-temp"
        try FileManager.default.createDirectory(atPath: linkedRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: linkedRoot + "/cmux-browser-screenshots", withDestinationPath: elsewhere)
        let cleanup = BrowserScreenshotCleanup(temporaryDirectory: linkedRoot)

        #expect(cleanup.remove(path: linkedRoot + "/cmux-browser-screenshots/surface-g.png") == .refused(.outsideDirectory))
        #expect(cleanup.remove(path: file) == .refused(.outsideDirectory))
        #expect(directory.exists(file))
    }

    @Test func reportsAMissingScreenshot() throws {
        let directory = try BrowserScreenshotDirectory()

        #expect(directory.cleanup.remove(path: directory.screenshots + "/surface-gone.png") == .missing)
    }

    @Test func reportsAnUnlinkFailureAndLeavesTheFile() throws {
        let directory = try BrowserScreenshotDirectory()
        let path = try directory.makeFile(directory.screenshots + "/surface-locked.png")
        #expect(chmod(directory.screenshots, 0o555) == 0)
        defer { chmod(directory.screenshots, 0o755) }

        #expect(directory.cleanup.remove(path: path) == .unlinkFailed(errno: EACCES))
        #expect(directory.exists(path))
    }

    @Test func defaultBaseIsTheResolvedSystemTemporaryDirectory() throws {
        let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(temporary) }

        #expect(BrowserScreenshotCleanup().baseDirectory == String(cString: temporary) + "/cmux-browser-screenshots")
    }
}
