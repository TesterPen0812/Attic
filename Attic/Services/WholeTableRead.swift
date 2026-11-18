import Foundation
import SwiftData

/// Every unfiltered read of a whole task, note or attachment table is built here, so a test can count those reads at
/// the production sites that make them (by file and function), not at a store's reload entry point. In release this is
/// exactly `FetchDescriptor<T>()`. The descriptor is built immediately before its fetch, so a read that fails before
/// the fetch is not counted.
enum WholeTableRead {
    static func all<T: PersistentModel>(_ type: T.Type, fileID: StaticString = #fileID,
                                        function: StaticString = #function) -> FetchDescriptor<T> {
        #if DEBUG
        let file = "\(fileID)".split(separator: "/").last.map(String.init) ?? "\(fileID)"
        ledger.record("\(T.self) \(file.replacingOccurrences(of: ".swift", with: "")).\(function)")
        #endif
        return FetchDescriptor<T>()
    }

    #if DEBUG
    static let ledger = Ledger()

    final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ site: String) { lock.withLock { counts[site, default: 0] += 1 } }
        func reset() { lock.withLock { counts = [:] } }
        /// Reads per site since the last reset, keyed "<Model> <File>.<function>".
        var bySite: [String: Int] { lock.withLock { counts } }
        /// Reads of one model's whole table since the last reset.
        func total<T: PersistentModel>(_ type: T.Type) -> Int {
            lock.withLock { counts.filter { $0.key.hasPrefix("\(T.self) ") }.values.reduce(0, +) }
        }
    }
    #endif
}
