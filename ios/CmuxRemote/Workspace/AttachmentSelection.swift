import Foundation

struct AttachmentSelection: Sendable {
    let url: URL
    let declaredMIMEType: String?

    init(url: URL, declaredMIMEType: String? = nil) {
        self.url = url
        self.declaredMIMEType = declaredMIMEType
    }
}
