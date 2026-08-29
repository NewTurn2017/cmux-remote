import Foundation
import Observation

/// Coordinates workspace attachment selection, photo staging, and command-draft insertion.
@MainActor
@Observable
final class AttachmentCoordinator {
    let store: AttachmentStore
    private(set) var isPreparingPhoto = false

    private let photoStager: any AttachmentPhotoStaging
    private var draftBlock: String?

    init(
        store: AttachmentStore,
        photoStager: any AttachmentPhotoStaging
    ) {
        self.store = store
        self.photoStager = photoStager
    }

    var isBusy: Bool {
        isPreparingPhoto || store.isUploading
    }

    func setHostGeneration(_ generation: Int) async {
        await store.setHostGeneration(generation)
    }

    func attachPhotoData(_ data: Data, hostGeneration: Int) async throws {
        guard !isBusy else { return }
        isPreparingPhoto = true
        draftBlock = nil
        var stagedSelection: AttachmentSelection?
        do {
            let selection = try await photoStager.stage(data)
            stagedSelection = selection
            await store.startUpload([selection], hostGeneration: hostGeneration)
            await store.waitForCurrentOperation()
            await photoStager.remove(selection)
            isPreparingPhoto = false
        } catch {
            if let stagedSelection {
                await photoStager.remove(stagedSelection)
            }
            isPreparingPhoto = false
            throw error
        }
    }

    func beginUpload(_ selections: [AttachmentSelection], hostGeneration: Int) async {
        guard !selections.isEmpty, !isBusy else { return }
        draftBlock = nil
        await store.startUpload(selections, hostGeneration: hostGeneration)
    }

    func mergedDraft(currentDraft: String, quotedPaths: [String]) -> String? {
        let nextBlock = quotedPaths.joined(separator: " ")
        guard !nextBlock.isEmpty, nextBlock != draftBlock else { return nil }
        var draft = currentDraft
        if let draftBlock, let trackedRange = draft.range(of: draftBlock) {
            draft.replaceSubrange(trackedRange, with: nextBlock)
        } else if draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") {
            draft.append(nextBlock)
        } else {
            draft.append(" \(nextBlock)")
        }
        draftBlock = nextBlock
        return draft
    }
}
