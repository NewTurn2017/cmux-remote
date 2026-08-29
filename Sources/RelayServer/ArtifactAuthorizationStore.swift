import Foundation

/// Holds short-lived, identity-bound authorization records for detected terminal files.
actor ArtifactAuthorizationStore {
    struct Scope: Hashable, Sendable {
        let deviceID: String
        let workspaceID: String
        let surfaceID: String

        init(deviceID: String, workspaceID: String, surfaceID: String) {
            self.deviceID = deviceID
            self.workspaceID = workspaceID
            self.surfaceID = surfaceID
        }
    }

    enum Source: String, Sendable, Equatable {
        case native
        case relayFallback = "relay_fallback"
    }

    struct FileIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let revision: String
    }

    struct Candidate: Sendable {
        let canonicalPath: String
        let displayName: String
        let kind: String
        let mimeType: String?
        let identity: FileIdentity
        let source: Source
    }

    struct Item: Sendable, Equatable {
        let id: String
        let displayName: String
        let kind: String
        let size: Int64
        let mimeType: String?
        let revision: String
    }

    struct RecordedGeneration: Sendable {
        let id: String
        let number: Int
        let source: Source
        let items: [Item]
    }

    struct Authorization: Sendable {
        let canonicalPath: String
        let source: Source
        let identity: FileIdentity
        let displayName: String
        let kind: String
        let mimeType: String?
    }

    struct LocatedAuthorization: Sendable {
        let scope: Scope
        let generationNumber: Int
        let authorization: Authorization
    }

    enum LookupError: Swift.Error, Equatable {
        case forbidden
        case expired
    }

    private struct StoredItem: Sendable {
        let id: String
        let candidate: Candidate
    }

    private struct Generation: Sendable {
        let id: String
        let number: Int
        let createdAt: TimeInterval
        let expiresAt: TimeInterval
        let source: Source
        let items: [StoredItem]
    }

    private struct SurfaceState: Sendable {
        var generations: [Generation]
        var lastAccess: UInt64
        var nextGenerationNumber: Int
    }

    private let now: @Sendable () async -> TimeInterval
    private let makeID: @Sendable () async -> String
    private var surfaces: [Scope: SurfaceState] = [:]
    private var accessCounter: UInt64 = 0

    init(
        now: @escaping @Sendable () async -> TimeInterval,
        makeID: @escaping @Sendable () async -> String = { UUID().uuidString }
    ) {
        self.now = now
        self.makeID = makeID
    }

    func record(scope: Scope, candidates: [Candidate], source: Source) async -> RecordedGeneration {
        let timestamp = await now()
        removeExpired(at: timestamp)
        accessCounter &+= 1

        let generationID = await makeID()
        var storedItems: [StoredItem] = []
        storedItems.reserveCapacity(min(candidates.count, 200))
        for candidate in candidates.prefix(200) {
            storedItems.append(StoredItem(id: await makeID(), candidate: candidate))
        }
        var state = surfaces[scope] ?? SurfaceState(
            generations: [], lastAccess: accessCounter, nextGenerationNumber: 1
        )
        let generation = Generation(
            id: generationID,
            number: state.nextGenerationNumber,
            createdAt: timestamp,
            expiresAt: timestamp + 600,
            source: source,
            items: storedItems
        )
        state.nextGenerationNumber &+= 1
        state.generations.append(generation)
        if state.generations.count > 4 {
            state.generations.removeFirst(state.generations.count - 4)
        }
        state.lastAccess = accessCounter
        surfaces[scope] = state
        evictSurfacesIfNeeded()

        return RecordedGeneration(
            id: generationID,
            number: generation.number,
            source: source,
            items: storedItems.map {
                Item(
                    id: $0.id,
                    displayName: $0.candidate.displayName,
                    kind: $0.candidate.kind,
                    size: $0.candidate.identity.size,
                    mimeType: $0.candidate.mimeType,
                    revision: $0.candidate.identity.revision
                )
            }
        )
    }

    func resolve(scope: Scope, generationNumber: Int, artifactID: String) async throws -> Authorization {
        guard var state = surfaces[scope],
              let generationIndex = state.generations.firstIndex(where: { $0.number == generationNumber })
        else { throw LookupError.forbidden }

        let timestamp = await now()
        let generation = state.generations[generationIndex]
        guard timestamp < generation.expiresAt else {
            state.generations.remove(at: generationIndex)
            if state.generations.isEmpty { surfaces.removeValue(forKey: scope) }
            else { surfaces[scope] = state }
            throw LookupError.expired
        }
        guard let item = generation.items.first(where: { $0.id == artifactID }) else {
            throw LookupError.forbidden
        }
        accessCounter &+= 1
        state.lastAccess = accessCounter
        surfaces[scope] = state
        return authorization(from: item)
    }

    func locate(deviceID: String, artifactID: String) async throws -> LocatedAuthorization {
        let timestamp = await now()
        for scope in Array(surfaces.keys) where scope.deviceID == deviceID {
            guard var state = surfaces[scope] else { continue }
            for generationIndex in state.generations.indices {
                let generation = state.generations[generationIndex]
                guard let item = generation.items.first(where: { $0.id == artifactID }) else { continue }
                guard timestamp < generation.expiresAt else {
                    state.generations.remove(at: generationIndex)
                    if state.generations.isEmpty { surfaces.removeValue(forKey: scope) }
                    else { surfaces[scope] = state }
                    throw LookupError.expired
                }
                accessCounter &+= 1
                state.lastAccess = accessCounter
                surfaces[scope] = state
                return LocatedAuthorization(
                    scope: scope,
                    generationNumber: generation.number,
                    authorization: authorization(from: item)
                )
            }
        }
        throw LookupError.forbidden
    }

    private func authorization(from item: StoredItem) -> Authorization {
        Authorization(
            canonicalPath: item.candidate.canonicalPath,
            source: item.candidate.source,
            identity: item.candidate.identity,
            displayName: item.candidate.displayName,
            kind: item.candidate.kind,
            mimeType: item.candidate.mimeType
        )
    }

    private func removeExpired(at timestamp: TimeInterval) {
        for scope in Array(surfaces.keys) {
            guard var state = surfaces[scope] else { continue }
            state.generations.removeAll { timestamp >= $0.expiresAt }
            if state.generations.isEmpty { surfaces.removeValue(forKey: scope) }
            else { surfaces[scope] = state }
        }
    }

    private func evictSurfacesIfNeeded() {
        while surfaces.count > 64,
              let oldest = surfaces.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            surfaces.removeValue(forKey: oldest)
        }
    }
}
