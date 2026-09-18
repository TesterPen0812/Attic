# Root native addendum — persistent ellipsis, 2026-09-13 14:58 UTC

User explicitly asked to check the permanently visible three dots. Read-only CUA inspection, no pointer or keyboard actions, respecting SWE-B exclusive interaction ownership.

Confirmed visually in the current pinned subpanel “Batch 3 attachment drop target”: all three rows (kbkjbjbjb, on\n, pno) show blue ellipses simultaneously. CUA native screenshot is attached to this conversation tool result. Accessibility reports focus in Add subtask… composer, not a row, and no row-action menu elements. Thus this is rendered/native evidence of a mismatch between hidden accessibility/actions state and visible glyphs. One pointer cannot hover all three separate rows simultaneously. Main panel not visible in this capture; do not claim direct root verification there yet.

Preview verified with hardened launcher at 14:58:54 UTC: PID38614, bundle com.taha.Attic.taskpanels.v2, mapped debug dylib SHA256 dba63f073107c75d720dfe52ac999d4e724bd047007282038a37e3939def679b. Not a stale preview explanation.

Checklist section2 FAIL for task rows in subpanel. Shared TaskRowView puts opacity on the Image inside native SwiftUI Menu label; whether native Menu image bridging drops that opacity is a causal hypothesis, not yet proven. Fix must hide the rendered menu affordance itself while reserving its footprint and retaining appropriate keyboard discovery. Verify native main and subpanel rows, focus, pointer exit and menu click behavior. Preserve frozen independent root report; this is later user-triggered native evidence.
