# Note attachment schema rollout

This branch adds `NoteAttachment` additively to the existing SwiftData model. It
does not deploy or alter the CloudKit Production schema.

## Development CloudKit

1. Build the Debug target with the existing Development CloudKit and
   development APNs settings.
2. On a development-only device/account, let the app run its existing
   `initializeCloudKitDevelopmentSchemaIfNeeded()` path. The schema bootstrap
   now includes `NoteAttachment`.
3. Inspect the Development container for the generated attachment record type,
   including the optional external-storage payload and all defaulted metadata.
4. Exercise multi-file imports, remote imports, deletion, and relaunch before
   changing any release configuration.

The Development store remains `development.store`; it must never be reused by a
Production build. Existing CloudKit observers, APNs registration, entitlements,
bundle identifiers, and store-selection rules are unchanged.

## Future Production step (not performed here)

After Development schema review and real-device two-way sync validation, deploy
the additive schema from CloudKit Dashboard to Production. Only then should a
new TestFlight Mac and iPhone build depend on the new record type. Increment
each platform build number, upload Mac and iPhone independently, install the
distributed builds, and complete the repository's full bidirectional sync,
priority/status, conflict, and deletion checklist. No Production schema
deployment, upload, installation, or live-device validation is part of this
branch.
