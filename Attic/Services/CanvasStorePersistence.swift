import Combine
import CoreData
import Foundation
import SwiftData

extension CanvasStore {
    /// Discard mutations that failed before `save()` was reached. SwiftData
    /// keeps inserts/updates in the context after a thrown validation or
    /// replica-resolution error; leaving those changes in place would let a
    /// later, unrelated canvas action persist a partial earlier operation.
    func discardPendingChanges(after error: Error) {
        let failureMessage = error.localizedDescription
        context.rollback()
        do {
            let warning = try reloadCanvas()
            lastErrorMessage = warning.map {
                "\(failureMessage) · \($0)"
            } ?? failureMessage
        } catch {
            lastErrorMessage = "\(failureMessage) · Reload failed: \(error.localizedDescription)"
        }
    }

    /// - Parameter previousSelection: The selection to reinstate when the save
    ///   fails. Board create/delete move `selectedCanvasID` before saving so the
    ///   saved presentation resolves the new board; a failed save must return
    ///   to the prior board rather than let reload fall back to the first live
    ///   board. Reload still falls back if that board is no longer live.
    @discardableResult
    func save(restoringSelectionOnFailure previousSelection: UUID? = nil) -> CanvasSaveOutcome {
        let savedPresentation: CanvasPresentationSnapshot
        do {
            // Resolve the pending mutation while the saved context is still
            // readable. Once persistence succeeds this value is a complete,
            // non-throwing fallback if a fresh context cannot be loaded.
            savedPresentation = try resolveCanvasPresentation(
                using: context,
                strokeCache: visibleStrokeCache,
                imageCache: visibleImageCache,
                permitsEquivalentSourceReuse: false
            )
        } catch {
            let preparationError = "Canvas could not prepare its saved presentation: "
                + error.localizedDescription
            rollBackFailedSave(restoringSelection: previousSelection)
            do {
                let warning = try reloadCanvas()
                lastErrorMessage = warning.map {
                    "\(preparationError) · \($0)"
                } ?? preparationError
            } catch {
                lastErrorMessage = "\(preparationError) · Reload failed: "
                    + error.localizedDescription
            }
            return .failed(lastErrorMessage ?? preparationError)
        }

        do {
            try persist(context)
            if CanvasCloudInfrastructurePolicy.isEnabled {
                cloudSyncProtection.noteLocalSave()
                reconcileProtectedCloudSyncActivity(for: .exportData)
            }

            do {
                let warning = try reloadCanvas(reusing: savedPresentation)
                lastErrorMessage = warning
                return .persisted(warning: warning)
            } catch {
                let refreshFailure = "Canvas saved, but refresh failed: \(error.localizedDescription)"
                let message = savedPresentation.warning.map {
                    "\(refreshFailure) · \($0)"
                } ?? refreshFailure
                applyCanvasPresentation(savedPresentation, replacingContext: nil)
                lastErrorMessage = message
                return .persistedButRefreshFailed(message)
            }
        } catch {
            let saveError = error.localizedDescription
            rollBackFailedSave(restoringSelection: previousSelection)
            do {
                let warning = try reloadCanvas()
                lastErrorMessage = warning.map { "\(saveError) · \($0)" } ?? saveError
            } catch {
                lastErrorMessage = "\(saveError) · Reload failed: \(error.localizedDescription)"
            }
            return .failed(lastErrorMessage ?? saveError)
        }
    }

    private func rollBackFailedSave(restoringSelection previousSelection: UUID?) {
        context.rollback()
        if let previousSelection, selectedCanvasID != previousSelection {
            selectedCanvasID = previousSelection
        }
    }

    func reloadCanvas() throws -> String? {
        try reloadCanvas(reusing: nil)
    }

    private func reloadCanvas(
        reusing cachedPresentation: CanvasPresentationSnapshot?
    ) throws -> String? {
        let freshContext = try makeFreshContext()
        let presentation = try resolveCanvasPresentation(
            using: freshContext,
            strokeCache: cachedPresentation?.strokeCache ?? visibleStrokeCache,
            imageCache: cachedPresentation?.imageCache ?? visibleImageCache,
            permitsEquivalentSourceReuse: cachedPresentation != nil
        )
        applyCanvasPresentation(presentation, replacingContext: freshContext)
        return presentation.warning
    }

    private func resolveCanvasPresentation(
        using sourceContext: ModelContext,
        strokeCache sourceStrokeCache: [CanvasReplicaKey: CanvasStrokeCacheEntry],
        imageCache sourceImageCache: [CanvasReplicaKey: CanvasImageCacheEntry],
        permitsEquivalentSourceReuse: Bool
    ) throws -> CanvasPresentationSnapshot {
        var replicas = try loadReplicas(sourceContext, selectedCanvasID)
        let boardReplicas = replicas.boards

        var warnings: [String] = []
        var omittedWarningCount = 0
        func recordWarning(_ warning: String) {
            if warnings.count < 3 {
                warnings.append(warning)
            } else {
                omittedWarningCount += 1
            }
        }

        var boardWinnerByID: [UUID: CanvasBoardItem] = [:]
        for replica in boardReplicas {
            if let existing = boardWinnerByID[replica.id] {
                if Self.prefersBoard(replica, over: existing) {
                    boardWinnerByID[replica.id] = replica
                }
            } else {
                boardWinnerByID[replica.id] = replica
            }
        }

        var resolvedBoards = boardWinnerByID.values
            .filter { !$0.tombstoned }
            .map(Self.canvasBoard(from:))
        // Legacy stores can contain Canvas content before a physical board
        // row exists. Materialise a virtual default only for live legacy
        // content. An explicit board tombstone must continue to win; otherwise
        // deleting the default canvas would make it reappear on refresh.
        if !resolvedBoards.contains(where: { $0.id == CanvasBoardItem.logicalBoardID }),
           boardWinnerByID[CanvasBoardItem.logicalBoardID] == nil,
           replicas.hasUnboardedLegacyDefaultContent {
            resolvedBoards.append(.defaultBoard)
        }
        if resolvedBoards.isEmpty {
            let defaultWasExplicitlyDeleted = boardWinnerByID[
                CanvasBoardItem.logicalBoardID
            ]?.tombstoned == true
            resolvedBoards = [
                defaultWasExplicitlyDeleted ? .recoveryBoard : .defaultBoard
            ]
        }
        resolvedBoards.sort(by: Self.boardComesBefore)

        var resolvedSelectedCanvasID = selectedCanvasID
        if !resolvedBoards.contains(where: { $0.id == resolvedSelectedCanvasID }) {
            resolvedSelectedCanvasID = resolvedBoards[0].id
        }
        let resolvedBoard = resolvedBoards.first { $0.id == resolvedSelectedCanvasID }
            ?? resolvedBoards[0]
        let resolvedGeneration = resolvedBoard.clearGeneration
        if resolvedSelectedCanvasID != selectedCanvasID {
            // The requested canvas is not live, so its content is not what will
            // be shown. The boards are re-read from the same context and resolve
            // identically; only the content rows differ.
            replicas = try loadReplicas(sourceContext, resolvedSelectedCanvasID)
        }
        let strokeReplicas = replicas.strokes
        let imageReplicas = replicas.images
        #if os(macOS)
        let semanticReplicas = replicas.semanticObjects
        #endif

        if let selectedReplica = boardWinnerByID[resolvedSelectedCanvasID],
           selectedReplica.formatVersion != CanvasStrokeCodec.currentVersion {
            recordWarning("The selected canvas format is newer than this version of Attic.")
        }

        var strokeWinnerByKey: [CanvasReplicaKey: CanvasStrokeItem] = [:]
        for replica in strokeReplicas where replica.canvasID == resolvedSelectedCanvasID {
            let key = CanvasReplicaKey(canvasID: replica.canvasID, id: replica.id)
            if let existing = strokeWinnerByKey[key] {
                if Self.prefersStroke(replica, over: existing) {
                    strokeWinnerByKey[key] = replica
                }
            } else {
                strokeWinnerByKey[key] = replica
            }
        }

        var nextStrokeCache: [CanvasReplicaKey: CanvasStrokeCacheEntry] = [:]
        nextStrokeCache.reserveCapacity(strokeWinnerByKey.count)
        var visibleStrokes: [CanvasStroke] = []
        visibleStrokes.reserveCapacity(strokeWinnerByKey.count)
        for key in strokeWinnerByKey.keys.sorted(by: Self.replicaKeyComesBefore) {
            guard let replica = strokeWinnerByKey[key],
                  replica.boardGeneration == resolvedGeneration,
                  !replica.tombstoned else {
                continue
            }
            if let cached = sourceStrokeCache[key] {
                let reusableCache: CanvasStrokeCacheEntry?
                if cached.matches(replica) {
                    reusableCache = cached
                } else if permitsEquivalentSourceReuse,
                          cached.representsSameCommittedValue(as: replica) {
                    reusableCache = cached.rebound(to: replica)
                } else {
                    reusableCache = nil
                }
                if let reusableCache {
                    nextStrokeCache[key] = reusableCache
                    visibleStrokes.append(reusableCache.stroke)
                    continue
                }
            }
            do {
                let geometry = try decodeStroke(replica.payload, replica.payloadVersion)
                let stroke = CanvasStroke(
                    id: replica.id,
                    canvasID: replica.canvasID,
                    color: geometry.color,
                    width: geometry.width,
                    points: geometry.points,
                    boardGeneration: replica.boardGeneration,
                    mutationVersion: replica.mutationVersion,
                    createdAt: replica.createdAt,
                    updatedAt: replica.updatedAt
                )
                nextStrokeCache[key] = CanvasStrokeCacheEntry(
                    sourceReplicaID: String(reflecting: replica.persistentModelID),
                    payloadVersion: replica.payloadVersion,
                    payloadByteCount: replica.payload.count,
                    boardGeneration: replica.boardGeneration,
                    mutationVersion: replica.mutationVersion,
                    createdAt: replica.createdAt,
                    updatedAt: replica.updatedAt,
                    stroke: stroke
                )
                visibleStrokes.append(stroke)
            } catch {
                recordWarning(
                    "Stroke \(replica.id.uuidString) was retained but could not be rendered: "
                        + error.localizedDescription
                )
            }
        }
        visibleStrokes.sort(by: Self.strokeComesBefore)

        var imageWinnerByKey: [CanvasReplicaKey: CanvasImageItem] = [:]
        for replica in imageReplicas where replica.canvasID == resolvedSelectedCanvasID {
            let key = CanvasReplicaKey(canvasID: replica.canvasID, id: replica.id)
            if let existing = imageWinnerByKey[key] {
                if Self.prefersImage(replica, over: existing) {
                    imageWinnerByKey[key] = replica
                }
            } else {
                imageWinnerByKey[key] = replica
            }
        }

        var nextImageCache: [CanvasReplicaKey: CanvasImageCacheEntry] = [:]
        nextImageCache.reserveCapacity(imageWinnerByKey.count)
        var visibleImages: [CanvasPlacedImage] = []
        visibleImages.reserveCapacity(imageWinnerByKey.count)
        for key in imageWinnerByKey.keys.sorted(by: Self.replicaKeyComesBefore) {
            guard let replica = imageWinnerByKey[key],
                  replica.boardGeneration == resolvedGeneration,
                  !replica.tombstoned else {
                continue
            }
            let transform = CanvasImageTransform(
                center: CanvasPoint(x: replica.centerX, y: replica.centerY),
                width: replica.width,
                height: replica.height,
                zIndex: replica.zIndex
            )
            // Validate the row through its scalar columns. The previous
            // `replica.encodedData.isEmpty` check ran before the cache lookup
            // below and therefore faulted every image blob on the board on
            // every save (CANVAS-016/PERF-08).
            guard replica.pixelWidth > 0,
                  replica.pixelHeight > 0,
                  transform.isValid,
                  replica.pixelWidth <= Int64(Int.max),
                  replica.pixelHeight <= Int64(Int.max),
                  replica.hasEncodedPayload else {
                recordWarning("Image \(replica.id.uuidString) was retained but has invalid data.")
                continue
            }
            if let cached = sourceImageCache[key] {
                let reusableCache: CanvasImageCacheEntry?
                if cached.matches(replica) {
                    reusableCache = cached
                } else if permitsEquivalentSourceReuse,
                          cached.representsSameCommittedValue(as: replica) {
                    reusableCache = cached.rebound(to: replica)
                } else {
                    reusableCache = nil
                }
                if let reusableCache {
                    nextImageCache[key] = reusableCache
                    visibleImages.append(reusableCache.image)
                    continue
                }
            }
            // The transform or version changed, but the payload may not have.
            // When the cached entry proves the bytes are the same, reuse the
            // resident payload instead of faulting external storage again: a
            // move or resize must cost no image I/O (CANVAS-016/PERF-08).
            let reusablePayloadSource = sourceImageCache[key].flatMap {
                entry -> CanvasImageCacheEntry? in
                if entry.contentMatches(replica)
                    || (permitsEquivalentSourceReuse && entry.contentValueMatches(replica)) {
                    return entry
                }
                return nil
            }
            let contentToken = reusablePayloadSource?.image.contentToken ?? UUID()
            let payload = reusablePayloadSource?.image.encodedData
                ?? replica.materialisedPayload
            let payloadMetadata = reusablePayloadSource?.payloadMetadata
                ?? replica.resolvedPayloadMetadata
                ?? .compute(for: payload)
            let image = CanvasPlacedImage(
                id: replica.id,
                canvasID: replica.canvasID,
                contentToken: contentToken,
                encodedData: payload,
                contentType: replica.contentType,
                pixelWidth: Int(replica.pixelWidth),
                pixelHeight: Int(replica.pixelHeight),
                transform: transform,
                boardGeneration: replica.boardGeneration,
                mutationVersion: replica.mutationVersion,
                createdAt: replica.createdAt,
                updatedAt: replica.updatedAt,
                payloadMetadata: payloadMetadata
            )
            nextImageCache[key] = CanvasImageCacheEntry(
                sourceReplicaID: String(reflecting: replica.persistentModelID),
                payloadMetadata: payloadMetadata,
                contentType: replica.contentType,
                pixelWidth: replica.pixelWidth,
                pixelHeight: replica.pixelHeight,
                centerX: replica.centerX,
                centerY: replica.centerY,
                width: replica.width,
                height: replica.height,
                zIndex: replica.zIndex,
                boardGeneration: replica.boardGeneration,
                mutationVersion: replica.mutationVersion,
                createdAt: replica.createdAt,
                updatedAt: replica.updatedAt,
                image: image
            )
            visibleImages.append(image)
        }
        visibleImages.sort(by: Self.imageComesBefore)

        #if os(macOS)
        let semanticGroups = Dictionary(grouping: semanticReplicas.filter {
            $0.canvasID == resolvedSelectedCanvasID
        }, by: \.id)
        let visibleSemanticObjects = semanticGroups.values.compactMap { rows -> CanvasSemanticObject? in
            guard let winner = Self.winningSemanticReplica(rows),
                  !winner.tombstoned, winner.boardGeneration == resolvedGeneration else { return nil }
            let object = CanvasSemanticObject(winner)
            guard object.transform.isValid, object.rotation.isFinite else {
                recordWarning("A canvas object was retained but its position is invalid.")
                return nil
            }
            if object.content == nil { recordWarning("An unsupported canvas object was retained.") }
            return object
        }.sorted { lhs, rhs in
            if lhs.transform.zIndex != rhs.transform.zIndex { return lhs.transform.zIndex < rhs.transform.zIndex }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        #endif

        if omittedWarningCount > 0 {
            warnings.append("\(omittedWarningCount) additional canvas warning(s) were omitted.")
        }

        var presentation = CanvasPresentationSnapshot(
            canvases: resolvedBoards,
            selectedCanvasID: resolvedSelectedCanvasID,
            boardGeneration: resolvedGeneration,
            strokeCache: nextStrokeCache,
            imageCache: nextImageCache,
            strokes: visibleStrokes,
            images: visibleImages,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " · ")
        )
        #if os(macOS)
        presentation.semanticObjects = visibleSemanticObjects
        #endif
        return presentation
    }

    private func applyCanvasPresentation(
        _ presentation: CanvasPresentationSnapshot,
        replacingContext replacementContext: ModelContext?
    ) {
        if let replacementContext {
            context = replacementContext
        }
        let strokeFingerprint = CanvasStrokeCollectionFingerprint.value(
            for: presentation.strokes
        )
        var change = CanvasStoreContentChange.unchanged
        change.boardsChanged = canvases != presentation.canvases
        change.selectionChanged = selectedCanvasID != presentation.selectedCanvasID
        change.boardGenerationChanged = boardGeneration != presentation.boardGeneration
        change.strokesChanged = publishedStrokeFingerprint != strokeFingerprint
        // `CanvasPlacedImage` equality compares scalar payload metadata rather
        // than the payload itself, so this stays a cheap per-element compare.
        change.imagesChanged = images != presentation.images
        #if os(macOS)
        change.semanticObjectsChanged = semanticObjects != presentation.semanticObjects
        #endif
        if requiresFullContentComparison {
            change = .unknown
            requiresFullContentComparison = false
        }

        canvases = presentation.canvases
        selectedCanvasID = presentation.selectedCanvasID
        boardGeneration = presentation.boardGeneration
        visibleStrokeCache = presentation.strokeCache
        visibleImageCache = presentation.imageCache
        strokes = presentation.strokes
        images = presentation.images
        publishedStrokeFingerprint = strokeFingerprint
        #if os(macOS)
        semanticObjects = presentation.semanticObjects
        #endif
        lastContentChange = change
        if change.hasAnyChange {
            contentRevision &+= 1
        }
        revision &+= 1
    }

    /// Gives legacy image rows their scalar payload metadata so later resolves
    /// can validate them without faulting the external-storage blob.
    ///
    /// This writes derived columns only: it never touches `mutationVersion`,
    /// `updatedAt`, `boardGeneration` or `tombstoned`, so it cannot change which
    /// replica wins, make two replicas look divergent, or alter user content.
    /// Failure is not reported: the store simply keeps using the slower
    /// byte-comparison path for those rows.
    func backfillLegacyImagePayloadMetadata() {
        guard !context.hasChanges else { return }
        do {
            let rows = try context.fetchCanvasReplicas(FetchDescriptor<CanvasImageItem>(
                predicate: #Predicate { $0.contentDigest == "" }
            ))
            var changed = false
            for row in rows where row.backfillPayloadMetadataIfNeeded() {
                changed = true
            }
            guard changed else { return }
            try persist(context)
        } catch {
            context.rollback()
        }
    }

    func ensureSelectedBoardReplicaExists(at timestamp: Date) throws {
        guard try storedBoardReplicas(matching: selectedCanvasID).isEmpty else {
            return
        }
        let board = selectedCanvas
        context.insert(CanvasBoardItem(
            id: board.id,
            name: board.name,
            sortIndex: board.sortIndex,
            formatVersion: CanvasStrokeCodec.currentVersion,
            clearGeneration: board.clearGeneration,
            mutationVersion: max(board.mutationVersion, 1),
            tombstoned: false,
            createdAt: board.createdAt == .distantPast ? timestamp : board.createdAt,
            updatedAt: timestamp
        ))
    }

    func storedBoardReplicas(matching id: UUID) throws -> [CanvasBoardItem] {
        try context.fetchCanvasReplicas(FetchDescriptor<CanvasBoardItem>(
            predicate: #Predicate { $0.id == id }
        ))
    }

    /// Above this many identifiers a mutation reads the selected canvas and
    /// filters in memory, keeping the SQL `IN` list well under SQLite's bound
    /// variable limit. Either way every physical replica of each id is found.
    static let replicaIdentifierPredicateLimit = 512

    func storedStrokeReplicas(
        matching ids: Set<UUID>
    ) throws -> [UUID: [CanvasStrokeItem]] {
        guard !ids.isEmpty else { return [:] }
        let canvasID = selectedCanvasID
        let descriptor: FetchDescriptor<CanvasStrokeItem>
        if ids.count <= Self.replicaIdentifierPredicateLimit {
            let idList = Array(ids)
            descriptor = FetchDescriptor(predicate: #Predicate {
                $0.canvasID == canvasID && idList.contains($0.id)
            })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.canvasID == canvasID })
        }
        return Dictionary(
            grouping: try context.fetchCanvasReplicas(descriptor).filter {
                $0.canvasID == canvasID && ids.contains($0.id)
            },
            by: \.id
        )
    }

    func storedImageReplicas(
        matching ids: Set<UUID>
    ) throws -> [UUID: [CanvasImageItem]] {
        guard !ids.isEmpty else { return [:] }
        let canvasID = selectedCanvasID
        let descriptor: FetchDescriptor<CanvasImageItem>
        if ids.count <= Self.replicaIdentifierPredicateLimit {
            let idList = Array(ids)
            descriptor = FetchDescriptor(predicate: #Predicate {
                $0.canvasID == canvasID && idList.contains($0.id)
            })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.canvasID == canvasID })
        }
        return Dictionary(
            grouping: try context.fetchCanvasReplicas(descriptor).filter {
                $0.canvasID == canvasID && ids.contains($0.id)
            },
            by: \.id
        )
    }

    /// Returns how many content objects (strokes, images, objects) it hid.
    @discardableResult
    func tombstoneAllContent(canvasID: UUID, at timestamp: Date) throws -> Int {
        var hidden = 0
        #if os(macOS)
        hidden += try tombstoneSemanticObjects(canvasID: canvasID, at: timestamp)
        #endif
        let strokeGroups = Dictionary(
            grouping: try context.fetchCanvasReplicas(FetchDescriptor<CanvasStrokeItem>(
                predicate: #Predicate { $0.canvasID == canvasID }
            )),
            by: \.id
        )
        for (id, replicas) in strokeGroups {
            let winner = try Self.winningStrokeReplica(in: replicas)
            // Already-deleted content keeps its own deletion time: only what
            // this delete hides carries the board's `deletedAt`, which is how
            // `restoreCanvas` knows what to bring back.
            guard !winner.tombstoned else { continue }
            hidden += 1
            let nextVersion = try Self.nextMutationVersion(
                after: replicas.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            for replica in replicas {
                replica.payloadVersion = winner.payloadVersion
                replica.payload = winner.payload
                replica.boardGeneration = winner.boardGeneration
                replica.mutationVersion = nextVersion
                replica.tombstoned = true
                replica.createdAt = winner.createdAt
                replica.updatedAt = timestamp
                replica.deletedAt = timestamp
            }
        }

        let imageGroups = Dictionary(
            grouping: try context.fetchCanvasReplicas(FetchDescriptor<CanvasImageItem>(
                predicate: #Predicate { $0.canvasID == canvasID }
            )),
            by: \.id
        )
        for (id, replicas) in imageGroups {
            let winner = try Self.winningImageReplica(in: replicas)
            guard !winner.tombstoned else { continue }
            hidden += 1
            let nextVersion = try Self.nextMutationVersion(
                after: replicas.map(\.mutationVersion).max() ?? 0,
                objectID: id
            )
            for replica in replicas {
                Self.copyImagePayload(from: winner, to: replica)
                replica.boardGeneration = winner.boardGeneration
                replica.mutationVersion = nextVersion
                replica.tombstoned = true
                replica.createdAt = winner.createdAt
                replica.updatedAt = timestamp
                replica.deletedAt = timestamp
            }
        }
        return hidden
    }

}
