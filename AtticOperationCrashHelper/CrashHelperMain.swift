import Darwin
import Foundation
import SwiftData

// This executable is embedded only in the test host. It never uses a default
// app store, invokes AppKit, or permits a fixture outside the inherited tmp root.
#if !ATTIC_LOCAL_ONLY || !ATTIC_OPERATION_CRASH_TESTS
#error("Crash helper requires local-only test instrumentation")
#endif

@MainActor
func runFixture() throws {
    guard CommandLine.arguments.count == 3,
          CommandLine.arguments[1] == "launch-probe" else { _exit(64) }
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        .resolvingSymlinksInPath()
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    guard root.path.hasPrefix(temporary.path + "/"),
          root.lastPathComponent.hasPrefix("AtticOperationCrash-") else { _exit(65) }
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
    @MainActor static func main() {
        do { try runFixture() } catch {
            fputs("Crash fixture failed: \(error)\n", stderr)
            _exit(74)
        }
    }
}
