#!/bin/zsh
# Prints the Core Data entity version hashes of the SwiftData models at a git
# revision (default: f2c737a, the last revision before Phase 0). The @Model
# classes are extracted verbatim from that revision and compiled on their own,
# so the output is independent of the current sources. SchemaMigrationTests
# pins these values to prove its fixture store has the previous app's schema.
set -euo pipefail
rev=${1:-f2c737a}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for model in TaskItem NoteItem NoteAttachment CanvasBoardItem CanvasStrokeItem CanvasImageItem CanvasSemanticObjectItem; do
  git -C "$root" show "${rev}:Attic/Models/${model}.swift" > "$work/$model.swift"
done
python3 - "$work" <<'PY'
import sys, os
work = sys.argv[1]
def model_block(src):
    i = src.index("@Model"); j = src.index("{", i); depth = 0
    for k in range(j, len(src)):
        if src[k] == "{": depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0: return src[i:k + 1]
names = ["TaskItem", "NoteItem", "NoteAttachment", "CanvasBoardItem", "CanvasStrokeItem", "CanvasImageItem", "CanvasSemanticObjectItem"]
blocks = [model_block(open(os.path.join(work, n + ".swift")).read()) for n in names]
open(os.path.join(work, "models.swift"), "w").write(
    "import Foundation\nimport SwiftData\nimport UniformTypeIdentifiers\n\n" + "\n\n".join(blocks) + "\n")
PY
cat > "$work/main.swift" <<'SWIFT'
import CoreData
import Foundation
import SwiftData

// Stubs for types that only computed properties and initialisers mention;
// they do not take part in the stored schema.
struct TaskImageReference: Codable { let id: UUID }
enum TaskStatus: String { case todo, inProgress, done, backlog }
enum TaskPriority: String { case none, low, medium, high }
enum CanvasImagePlacement { static let minimumDimension = 48.0 }
struct CanvasImagePayloadMetadata {
    let byteCount: Int
    let digest: String
    static func compute(for data: Data) -> CanvasImagePayloadMetadata { .init(byteCount: data.count, digest: "") }
}

let model = NSManagedObjectModel.makeManagedObjectModel(for: [
    TaskItem.self, NoteItem.self, NoteAttachment.self, CanvasBoardItem.self,
    CanvasStrokeItem.self, CanvasImageItem.self, CanvasSemanticObjectItem.self
])!
for (name, hash) in model.entityVersionHashesByName.sorted(by: { $0.key < $1.key }) {
    print("\"\(name)\": \"\(hash.base64EncodedString())\",")
}
SWIFT
xcrun swiftc -target arm64-apple-macos26.0 "$work/models.swift" "$work/main.swift" -o "$work/hashes" >/dev/null
"$work/hashes"
