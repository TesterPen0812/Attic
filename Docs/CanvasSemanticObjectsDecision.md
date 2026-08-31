# Canvas semantic text and shape storage decision

Status: approval required before implementation

Finding: C-05

## Why a storage change is required

Current shapes are encoded as ordinary `CanvasStrokeItem` point lists, so after placement they are indistinguishable from freehand ink. Current text is rendered into image bytes and stored as `CanvasImageItem`, so its characters, font choices, and paragraph structure cannot be recovered for editing. Existing rows do not contain enough information to reconstruct semantic shapes or text safely.

Changing only the UI would therefore be misleading. Editable text and shape selection require a new persisted semantic object type. This is an additive SwiftData schema change and is not authorized by the current fixing task without an explicit user decision.

## Proposed additive model

Add `CanvasSemanticObjectItem` to every macOS container schema alongside the existing board, stroke, and image models. Do not remove, rename, or reinterpret any existing property or model.

The proposed row contains only defaulted, non-unique scalar/data fields and no relationships:

- `id: UUID` — logical duplicate-safe object UUID;
- `canvasID: UUID` — owning logical page UUID;
- `kind: String` — versioned token, initially `shape` or `text`;
- `payloadVersion: Int` — semantic content codec version;
- `payload: Data` — versioned shape/text content, not a rasterization;
- `centerX`, `centerY`, `width`, `height`, `rotation: Double` — transform columns so movement/resizing does not rewrite content;
- `zIndex: Int64` — shared layer ordering;
- `boardGeneration: Int64` — clear-generation visibility;
- `mutationVersion: Int64` — duplicate-safe winner/mutation ordering;
- `tombstoned: Bool` plus `createdAt`, `updatedAt`, and optional `deletedAt`.

Shape payload v1 stores the shape kind and semantic ink style. Text payload v1 stores the Unicode text, font size/weight token, semantic foreground token, and alignment. Unknown kinds or payload versions remain stored and render as non-destructive unsupported-object placeholders.

## Compatibility and migration plan

1. Register the new model additively in the local macOS SwiftData schemas. Do not activate CloudKit, APNs, mobile, Production schema work, or former-owner containers.
2. Open copied synthetic fixtures representing empty, current, duplicate-UUID, cleared-generation, corrupt-payload, and large local stores. Confirm lightweight additive opening and rollback behavior before opening any isolated preview store.
3. Preserve every existing `CanvasStrokeItem` and `CanvasImageItem` byte-for-byte. There is no automatic conversion:
   - historical shapes cannot be distinguished reliably from hand-drawn strokes;
   - historical text images cannot be distinguished reliably from ordinary images or converted back to exact text.
4. Render legacy strokes/images and new semantic objects together using the same page generation and deterministic z-order rules.
5. New shape/text placement writes only the semantic model after activation. Existing legacy rows remain selectable/renderable according to their real capabilities; they are never silently upgraded.
6. Apply mutations to every physical replica with the same logical UUID. Refresh deduplicates only for presentation and never deletes a replica as reconciliation.
7. Extend clear/Undo/Redo as one transaction across strokes, images, and semantic objects. Add save-failure and fresh-context durability regressions before enabling the UI.
8. Validate an isolated `com.taha.Attic.*` preview and separate local store. Never copy, reset, migrate, or replace the official app's store as a debugging shortcut.

## Rollback and user-data safety

The code must tolerate a store that already contains the additive model if the feature is later disabled. Rollback means stopping new semantic writes while continuing to retain and render supported semantic rows; it does not mean deleting the model or downgrading the store. If additive opening fails in fixture validation, implementation stops before any real preview store is opened and the schema change is not shipped.

## Decision requested

Approve or reject this additive, legacy-preserving `CanvasSemanticObjectItem` plan. Approval authorizes implementation and isolated migration validation only; it does not authorize CloudKit/mobile activation, Production schema deployment, destructive conversion, or access to the official user store.
