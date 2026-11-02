# iPhone activation decisions

**Status: provisional; owner to confirm.** These are the six engineering defaults from activation plan §8 for this branch. Owner review of the branch is required before any merge.

1. **Canvas on iPhone at first.** Default: new Draw boards sync and are editable (the design includes Draw). Their sync waits for the Mac's Draw schema to freeze. Old Canvas boards are not shown or synced.
2. **Visible conflict review.** Default: whole-note revisions; an offline fork shows both versions with "keep this / keep both". The same review covers duplicate task notes and edit-versus-delete. Automatic paragraph merge comes later.
3. **Attachment download policy.** Default: all metadata everywhere; files download when opened; recent and pinned items cached; a per-note "Keep offline". Nothing is ever shown as deleted while it's still downloading.
4. **History on iPhone.** Default: versions and Claude's pending proposals sync. The phone shows history and can restore (a restore is a new revision). Proposals are reviewed on the Mac in the first release; Undo stays per device.
5. **Account switching.** Default: one private iCloud account per library. On sign-out or a different account, sync pauses, local data stays on the device, and nothing uploads to the new account without asking. A device that comes back after a long time offline re-fetches before it sends.
6. **Minimum iOS.** Default: iOS 26, matching the Mac's macOS 26 and the design's glass capsules. The dormant target's iOS 17 would mean back-porting shared code.
