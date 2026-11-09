import Foundation

/// Parameters for `surface.browser.capture`. The relay asks cmux for the image; the client sends only ids.
public struct SurfaceBrowserCaptureRequest: Codable, Sendable, Equatable {
    /// Workspace containing the browser surface.
    public var workspaceId: String
    /// Browser surface to capture.
    public var surfaceId: String

    /// Creates a browser-capture request.
    public init(workspaceId: String, surfaceId: String) {
        self.workspaceId = workspaceId; self.surfaceId = surfaceId
    }
    private enum CodingKeys: String, CodingKey {
        case workspaceId, surfaceId
    }
}
