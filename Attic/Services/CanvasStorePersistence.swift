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

    @discardableResult
    func save() -> Bool {
        do {
            try persist(context)
            cloudSyncProtection.noteLocalSave()
            reconcileProtectedCloudSyncActivity(for: .exportData)

            do {
                lastErrorMessage = try reloadCanvas()
            } catch {
                lastErrorMessage = "Canvas saved, but refresh failed: \(error.localizedDescription)"
                revision &+= 1
            }
            return true
        } catch {
            let saveError = error.localizedDescription
            context.rollback()
            do {
                let warning = try reloadCanvas()
                lastErrorMessage = warning.map { "\(saveError) · \($0)" } ?? saveError
            } catch {
                lastErrorMessage = "\(saveError) · Reload failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    func reloadCanvas() throws -> String? {
        let refreshedContext = ModelContext(container)
        let boardReplicas = try refreshedContext.fetch(FetchDescriptor<CanvasBoardItem>())
        let strokeReplicas = try refreshedContext.fetch(FetchDescriptor<CanvasStrokeItem>())
        let imageReplicas = try refreshedContext.fetch(FetchDescriptor<CanvasImageItem>())

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
        let hasLiveLegacyDefaultContent = strokeReplicas.contains {
            $0.canvasID == CanvasBoardItem.logicalBoardID && !$0.tombstoned
        } || imageReplicas.contains {
            $0.canvasID == CanvasBoardItem.logicalBoardID && !$0.tombstoned
        }
        if !resolvedBoards.contains(where: { $0.id == CanvasBoardItem.logicalBoardID }),
           boardWinnerByID[CanvasBoardItem.logicalBoardID] == nil,
           hasLiveLegacyDefaultContent {
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

        if !resolvedBoards.contains(where: { $0.id == selectedCanvasID }) {
            selectedCanvasID = resolvedBoards[0].id
        }
        let resolvedBoard = resolvedBoards.first { $0.id == selectedCanvasID }
            ?? resolvedBoards[0]
        let resolvedGeneration = resolvedBoard.clearGeneration

        if let selectedReplica = boardWinnerByID[selectedCanvasID],
           selectedReplica.formatVersion != CanvasStrokeCodec.currentVersion {
            recordWarning("The selected canvas format is newer than this version of Attic.")
        }

        var strokeWinnerByKey: [CanvasReplicaKey: CanvasStrokeItem] = [:]
        for replica in strokeReplicas where replica.canvasID == selectedCanvasID {
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
            if let cached = visibleStrokeCache[key], cached.matches(replica) {
                nextStrokeCache[key] = cached
                visibleStrokes.append(cached.stroke)
                continue
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
        for replica in imageReplicas where replica.canvasID == selectedCanvasID {
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
            guard !replica.encodedData.isEmpty,
                  replica.pixelWidth > 0,
                  replica.pixelHeight > 0,
                  transform.isValid,
                  replica.pixelWidth <= Int64(Int.max),
                  replica.pixelHeight <= Int64(Int.max) else {
                recordWarning("Image \(replica.id.uuidString) was retained but has invalid data.")
                continue
            }
            if let cached = visibleImageCache[key], cached.matches(replica) {
                nextImageCache[key] = cached
                visibleImages.append(cached.image)
                continue
            }
            let contentToken = visibleImageCache[key]
                .flatMap { $0.contentMatches(replica) ? $0.image.contentToken : nil }
                ?? UUID()
            let image = CanvasPlacedImage(
                id: replica.id,
                canvasID: replica.canvasID,
                contentToken: contentToken,
                encodedData: replica.encodedData,
                contentType: replica.contentType,
                pixelWidth: Int(replica.pixelWidth),
                pixelHeight: Int(replica.pixelHeight),
                transform: transform,
                boardGeneration: replica.boardGeneration,
                mutationVersion: replica.mutationVersion,
                createdAt: replica.createdAt,
                updatedAt: replica.updatedAt
            )
            nextImageCache[key] = CanvasImageCacheEntry(
                sourceReplicaID: String(reflecting: replica.persistentModelID),
                encodedByteCount: replica.encodedData.count,
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

        if omittedWarningCount > 0 {
            warnings.append("\(omittedWarningCount) additional canvas warning(s) were omitted.")
        }

        context = refreshedContext
        canvases = resolvedBoards
        boardGeneration = resolvedGeneration
        visibleStrokeCache = nextStrokeCache
        visibleImageCache = nextImageCache
        strokes = visibleStrokes
        images = visibleImages
        revision &+= 1
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
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
        try context.fetch(FetchDescriptor<CanvasBoardItem>()).filter { $0.id == id }
    }

    func storedStrokeReplicas(
        matching ids: Set<UUID>
    ) throws -> [UUID: [CanvasStrokeItem]] {
        guard !ids.isEmpty else { return [:] }
        let stored = try context.fetch(FetchDescriptor<CanvasStrokeItem>())
        return Dictionary(
            grouping: stored.filter {
                $0.canvasID == selectedCanvasID && ids.contains($0.id)
            },
            by: \.id
        )
    }

    func storedImageReplicas(
        matching ids: Set<UUID>
    ) throws -> [UUID: [CanvasImageItem]] {
        guard !ids.isEmpty else { return [:] }
        let stored = try context.fetch(FetchDescriptor<CanvasImageItem>())
        return Dictionary(
            grouping: stored.filter {
                $0.canvasID == selectedCanvasID && ids.contains($0.id)
            },
            by: \.id
        )
    }

    func tombstoneAllContent(canvasID: UUID, at timestamp: Date) throws {
        let strokeGroups = Dictionary(
            grouping: try context.fetch(FetchDescriptor<CanvasStrokeItem>())
                .filter { $0.canvasID == canvasID },
            by: \.id
        )
        for (id, replicas) in strokeGroups {
            let winner = try Self.winningStrokeReplica(in: replicas)
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
            grouping: try context.fetch(FetchDescriptor<CanvasImageItem>())
                .filter { $0.canvasID == canvasID },
            by: \.id
        )
        for (id, replicas) in imageGroups {
            let winner = try Self.winningImageReplica(in: replicas)
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
    }

}
