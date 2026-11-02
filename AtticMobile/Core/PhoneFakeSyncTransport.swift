#if ATTIC_CLOUD_SYNC && !ATTIC_LOCAL_ONLY
import Foundation

/// Deterministic private-database simulator. Every test account/environment
/// gets its own ledger, with durable operation-id deduplication on replay.
final class PhoneFakeSyncServer: PhoneFakeSyncTransport {
    private var lanes: [PhoneFakeSyncScope: [PhoneFakeSyncEnvelope]] = [:]
    private var known: [PhoneFakeSyncScope: [UUID: PhoneFakeSyncChange]] = [:]

    var connected = true
    var withholdNextReceipt = false
    var interruptNextAsset = false
    var reverseFetchOrder = false
    var duplicateOnFetch = false
    var excludeAssetBytesFromFetch = false

    func send(_ change: PhoneFakeSyncChange, scope: PhoneFakeSyncScope) throws -> PhoneFakeSyncReceipt? {
        guard connected else { throw PhoneFakeSyncFailure.offline }
        if case .assetBytes = change.body, interruptNextAsset {
            interruptNextAsset = false
            throw PhoneFakeSyncFailure.interruptedAsset
        }
        if let previous = known[scope]?[change.id] {
            guard previous == change else { throw PhoneFakeSyncFailure.immutableMismatch }
        } else {
            let sequence = Int64(lanes[scope, default: []].count) + 1
            lanes[scope, default: []].append(.init(sequence: sequence, change: change))
            known[scope, default: [:]][change.id] = change
        }
        if withholdNextReceipt {
            withholdNextReceipt = false
            return nil // server accepted; client crash/replay must be harmless
        }
        return .init(scope: scope, id: change.id, recordName: change.key.recordName, generation: change.generation)
    }

    func fetch(scope: PhoneFakeSyncScope, after: Int64) throws -> PhoneFakeSyncFetch {
        guard connected else { throw PhoneFakeSyncFailure.offline }
        let source = lanes[scope, default: []]
        var entries = source.filter { $0.sequence > after }
        if excludeAssetBytesFromFetch {
            entries.removeAll { if case .assetBytes = $0.change.body { return true }; return false }
        }
        if reverseFetchOrder { entries.reverse() }
        if duplicateOnFetch { entries += entries }
        return .init(scope: scope, changes: entries, upperBound: Int64(source.count), finished: true)
    }

    func ledger(_ scope: PhoneFakeSyncScope) -> [PhoneFakeSyncEnvelope] { lanes[scope, default: []] }
}

#if canImport(CloudKit)
import CloudKit

/// No CKSyncEngine is created, configured, started or sent network work in
/// Stage 5a. The owning delegate will forward its parsed events here when
/// Stage 5b is explicitly authorized, using the same tested transaction path.
@available(iOS 17, macOS 14, *)
final class PhoneFakeSyncCKSyncEngineBoundary {
    let engine: CKSyncEngine
    let session: PhoneFakeSyncSession

    init(engine: CKSyncEngine, session: PhoneFakeSyncSession) {
        self.engine = engine
        self.session = session
    }

    func fetchedRecordChanges(_ batch: PhoneFakeSyncFetch) throws { try session.receive(batch) }
    func sentRecordChange(_ receipt: PhoneFakeSyncReceipt) throws { try session.acknowledge(receipt) }
    func stateUpdated(_ engineState: Data, systemFields: [String: Data]) throws {
        try session.recordEngineState(engineState, recordFields: systemFields)
    }
    func accountChanged(to scope: PhoneFakeSyncScope?) { session.changeAccount(to: scope) }
}
#endif
#endif
