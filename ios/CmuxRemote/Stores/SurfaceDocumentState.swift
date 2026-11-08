enum SurfaceDocumentState: Equatable {
    case idle
    case loading
    case loaded(RenderedDocument)
    case failed(DocumentLoadFailure)
    /// The relay advertised documents but does not answer `surface.document.open`.
    case unsupported
}
