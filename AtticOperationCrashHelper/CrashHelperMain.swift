import Darwin
import Foundation
import SwiftData

// This executable is embedded only in the test host. It never uses a default
// app store, invokes AppKit, or permits a fixture outside the inherited tmp root.
#if !ATTIC_LOCAL_ONLY || !ATTIC_OPERATION_CRASH_TESTS
#error("Crash helper requires local-only test instrumentation")
#endif

@MainActor
func runFixture() async throws {
    guard CommandLine.arguments.count == 3,
          ["launch-probe", "seed-conversion", "convert", "writer-probe", "seed-purge", "purge"].contains(CommandLine.arguments[1]) else { _exit(64) }
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        .resolvingSymlinksInPath()
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    guard root.path.hasPrefix(temporary.path + "/"),
          root.lastPathComponent.hasPrefix("AtticOperationCrash-") else { _exit(65) }
    switch CommandLine.arguments[1] {
    case "seed-purge":
        try await WorkspaceCrashFixture.seedPurge(root); _exit(73)
    case "purge":
        guard try await WorkspaceCrashFixture.purge(root) == .committed else { _exit(75) }
        _exit(73)
    case "seed-conversion":
        try await WorkspaceCrashFixture.seed(root); _exit(73)
    case "convert":
        guard try await WorkspaceCrashFixture.convert(root) == .committed else { _exit(75) }
        _exit(73)
    case "writer-probe":
        do {
            _ = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            _exit(75)
        } catch WorkspaceFoundationError.writerAlreadyActive { _exit(76) }
    default: break
    }
    // The production schema registry is shared by host and child.
    let container = try PersistenceController.makeContainer(
        cloudSyncEnabled: false, storeDirectory: root
    )
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let task = TaskItem(title: "child task")
    let note = NoteItem(title: "child note", body: "durable child bytes")
    note.taskID = task.id
    context.insert(task)
    context.insert(note)
    try context.save()
    let names = container.schema.entities.map(\.name).sorted()
    try JSONEncoder().encode(names).write(to: root.appendingPathComponent("schema.json"))
    // No destructors or orderly container shutdown: the parent must reopen.
    _exit(73)
}

@main
struct CrashHelperMain {
    @MainActor static func main() async {
        do { try await runFixture() } catch {
            fputs("Crash fixture failed: \(error)\n", stderr)
            _exit(74)
        }
    }
}
